// Package gctsnet exposes a userspace Tailscale client for the iOS app
// (Layer ②: the phone dials the bridge's tailnet address through an
// in-process WireGuard stack — no NetworkExtension, no Tailscale app).
//
// Architecture: a local TCP proxy on 127.0.0.1 pipes bytes between the
// app's NWConnection (TLS stays end-to-end to the bridge) and the tsnet
// dialer, so the existing client code only swaps host/port.
package gctsnet

import (
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"

	"tailscale.com/tsnet"
	"tailscale.com/types/logger"
)

var (
	mu       sync.Mutex
	server   *tsnet.Server
	listener net.Listener
)

// Status returns the current state as a short string: "idle",
// "needs-login:<url>", "starting", "ready:<ip>", "error:<message>".
func Status() string {
	mu.Lock()
	defer mu.Unlock()
	if server == nil {
		return "idle"
	}
	client, err := server.LocalClient()
	if err != nil {
		return "starting"
	}
	status, err := client.Status(nil)
	if err != nil {
		return "starting"
	}
	switch status.BackendState {
	case "Running":
		if len(status.TailscaleIPs) > 0 {
			return "ready:" + status.TailscaleIPs[0].String()
		}
		return "starting"
	case "NeedsLogin":
		if status.AuthURL != "" {
			return "needs-login:" + status.AuthURL
		}
		return "needs-login:"
	default:
		return "starting"
	}
}

// LoginURL returns the interactive login URL when the node needs one.
func LoginURL() string {
	mu.Lock()
	defer mu.Unlock()
	if server == nil {
		return ""
	}
	client, err := server.LocalClient()
	if err != nil {
		return ""
	}
	if status, err := client.Status(nil); err == nil {
		return status.AuthURL
	}
	return ""
}

// Start joins the tailnet (authKey may be empty for interactive login) and
// blocks until ready or the timeout elapses. stateDir is an app-container
// writable path; hostname names this phone on the tailnet.
func Start(authKey, hostname, stateDir string, timeoutSeconds int64) string {
	mu.Lock()
	defer mu.Unlock()
	if server != nil {
		return Status()
	}
	if err := os.MkdirAll(filepath.Clean(stateDir), 0o700); err != nil {
		return "error:" + err.Error()
	}
	srv := &tsnet.Server{
		Hostname:  hostname,
		Dir:       filepath.Clean(stateDir),
		Ephemeral: true,
		Logf:      logger.Discard,
		AuthKey:   authKey,
	}
	server = srv

	// Drive startup: a throwaway listener forces the control connection.
	ln, err := srv.Listen("tcp", ":0")
	if err != nil {
		server = nil
		return "error:" + err.Error()
	}
	_ = ln.Close()

	deadline := time.Now().Add(time.Duration(timeoutSeconds) * time.Second)
	for time.Now().Before(deadline) {
		client, err := srv.LocalClient()
		if err == nil {
			if status, err := client.Status(nil); err == nil {
				if status.BackendState == "Running" && len(status.TailscaleIPs) > 0 {
					return "ready:" + status.TailscaleIPs[0].String()
				}
				if status.BackendState == "NeedsLogin" {
					return "needs-login:" + status.AuthURL
				}
			}
		}
		time.Sleep(300 * time.Millisecond)
	}
	return "timeout"
}

// StartProxy starts the local loopback proxy to a tailnet destination and
// returns "port:<n>" or "error:<message>". Call after Status is ready.
func StartProxy(destination string) string {
	mu.Lock()
	defer mu.Unlock()
	if server == nil {
		return "error:not started"
	}
	if listener != nil {
		return fmt.Sprintf("port:%d", listener.Addr().(*net.TCPAddr).Port)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "error:" + err.Error()
	}
	listener = ln
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func(local net.Conn) {
				defer local.Close()
				remote, err := server.Dial(context.Background(), "tcp", destination)
				if err != nil {
					return
				}
				defer remote.Close()
				done := make(chan struct{}, 2)
				go func() { io.Copy(remote, local); done <- struct{}{} }()
				go func() { io.Copy(local, remote); done <- struct{}{} }()
				<-done
			}(conn)
		}
	}()
	return fmt.Sprintf("port:%d", ln.Addr().(*net.TCPAddr).Port)
}

// Stop tears the tailnet session down.
func Stop() {
	mu.Lock()
	defer mu.Unlock()
	if listener != nil {
		listener.Close()
		listener = nil
	}
	if server != nil {
		server.Close()
		server = nil
	}
}
