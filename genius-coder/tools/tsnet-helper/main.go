// gc-tsnet-helper — embedded userspace Tailscale (tsnet) for the
// genius-coder bridge (Layer ②: no official Tailscale apps anywhere).
//
// It joins the tailnet in userspace (no TUN, no NetworkExtension), listens
// on the node's tailscale address, and pipes every TCP connection to the
// bridge's local listener. Stdout speaks a tiny line protocol for the Swift
// supervisor:
//
//	STATE <starting|needs-login|running>
//	LOGINURL <url>          (interactive login when no auth key given)
//	READY <ip> <port>       (accepting on the tailnet)
//	ERROR <message>
package main

import (
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strings"
	"time"

	"tailscale.com/tsnet"
	"tailscale.com/types/logger"
)

func emit(line string) {
	fmt.Println(line)
	os.Stdout.Sync()
}

func main() {
	authKey := flag.String("authkey", os.Getenv("TS_AUTHKEY"), "Tailscale auth key (or TS_AUTHKEY)")
	hostname := flag.String("hostname", "genius-coder-bridge", "tailnet hostname")
	bridge := flag.String("bridge", "127.0.0.1:8787", "local bridge address to proxy to")
	listenPort := flag.Uint("port", 8787, "tailnet listen port")
	controlURL := flag.String("login-server", os.Getenv("TS_LOGIN_SERVER"), "control server (headscale) URL")
	ephemeral := flag.Bool("ephemeral", true, "ephemeral node (disappears when idle/offline)")
	flag.Parse()

	stateDir := os.Getenv("GC_TSNET_STATE")
	if stateDir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			emit("ERROR no home directory: " + err.Error())
			os.Exit(1)
		}
		stateDir = home + "/.local/share/genius-coder/tsnet"
	}
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		emit("ERROR state dir: " + err.Error())
		os.Exit(1)
	}

	emit("STATE starting")
	srv := &tsnet.Server{
		Hostname:   *hostname,
		Dir:        stateDir,
		Ephemeral:  *ephemeral,
		Logf:       logger.Discard,
		ControlURL: *controlURL,
	}
	if *authKey != "" {
		srv.AuthKey = *authKey
	}

	loginURLSeen := false
	go func() {
		for range time.Tick(500 * time.Millisecond) {
			client, err := srv.LocalClient()
			if err != nil {
				continue
			}
			status, err := client.Status(nil)
			if err != nil {
				continue
			}
			if status.AuthURL != "" && !loginURLSeen {
				loginURLSeen = true
				emit("LOGINURL " + status.AuthURL)
			}
		}
	}()

	ln, err := srv.Listen("tcp", fmt.Sprintf(":%d", *listenPort))
	if err != nil {
		emit("ERROR listen: " + err.Error())
		os.Exit(1)
	}

	// Resolve our own tailscale address for the READY line.
	var selfIP string
	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		client, err := srv.LocalClient()
		if err == nil {
			status, err := client.Status(nil)
			if err == nil && len(status.TailscaleIPs) > 0 {
				selfIP = status.TailscaleIPs[0].String()
				break
			}
		}
		time.Sleep(300 * time.Millisecond)
	}
	if selfIP == "" {
		emit("ERROR no tailscale address after 60s (login failed?)")
		os.Exit(1)
	}
	emit(fmt.Sprintf("READY %s %d", selfIP, *listenPort))

	for {
		conn, err := ln.Accept()
		if err != nil {
			emit("ERROR accept: " + err.Error())
			time.Sleep(time.Second)
			continue
		}
		go proxy(conn, *bridge)
	}
}

func proxy(tailnetConn net.Conn, bridgeAddr string) {
	defer tailnetConn.Close()
	bridgeConn, err := net.DialTimeout("tcp", bridgeAddr, 5*time.Second)
	if err != nil {
		log.Printf("bridge dial: %v", err)
		return
	}
	defer bridgeConn.Close()
	done := make(chan struct{}, 2)
	go func() { io.Copy(bridgeConn, tailnetConn); done <- struct{}{} }()
	go func() { io.Copy(tailnetConn, bridgeConn); done <- struct{}{} }()
	<-done
	_ = strings.TrimSpace("") // keep strings import for future use
}
