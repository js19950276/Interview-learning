'use strict';
/**
 * MJCore — 淘宝双11满减凑单核心算法
 * 金额一律用「分」（整数）运算，避免浮点误差。
 * 兼容 node（module.exports）与浏览器（window.MJCore）。
 */
const MJCore = (() => {

  // ---------- 金额转换 ----------

  /** 把 '89' / '89.5' / '89.55' / '1,299.00' / 12.34 转为分；非法输入抛错 */
  function toCents(input) {
    let s = String(input ?? '').trim().replace(/,/g, '');
    if (typeof input === 'number') s = input.toFixed(2);
    if (!/^\d+(\.\d{1,2})?$/.test(s)) throw new Error('价格格式不正确：' + input);
    const [yuan, dec = ''] = s.split('.');
    return parseInt(yuan, 10) * 100 + parseInt(dec.padEnd(2, '0'), 10);
  }

  /** 分 -> '89.00' */
  function fmt(cents) {
    const sign = cents < 0 ? '-' : '';
    const abs = Math.abs(Math.round(cents));
    return sign + Math.floor(abs / 100) + '.' + String(abs % 100).padStart(2, '0');
  }

  // ---------- 满减计算 ----------

  /**
   * 单池结算：小计、已享档数与折扣、距下一档差距、到手价。
   * 恰为整数倍时 gap 为整档（下一档需再加满 X）。
   */
  function poolSummary(items, pool) {
    const subtotal = items
      .filter((i) => i.poolId === pool.id)
      .reduce((acc, i) => acc + i.price * (i.qty || 1), 0);
    const tiers = Math.floor(subtotal / pool.per);
    const discount = tiers * pool.off;
    const rem = subtotal % pool.per;
    const gap = rem === 0 ? pool.per : pool.per - rem;
    return { subtotal, tiers, discount, gap, effective: subtotal - discount };
  }

  /**
   * 整车结算：分池汇总 + 整单券（门槛按满减后总价判定，每张独立判）。
   */
  function cartSummary(items, pools, coupons = []) {
    const perPool = {};
    for (const p of pools) perPool[p.id] = poolSummary(items, p);
    const totalBefore = Object.values(perPool).reduce((a, s) => a + s.subtotal, 0);
    const totalMJ = Object.values(perPool).reduce((a, s) => a + s.discount, 0);
    const afterMJ = totalBefore - totalMJ;
    let totalCoupon = 0;
    const couponResults = (coupons || []).map((c) => {
      const ok = afterMJ >= c.min;
      if (ok) totalCoupon += c.off;
      return { coupon: c, ok, gap: ok ? 0 : c.min - afterMJ };
    });
    const totalAfter = afterMJ - totalCoupon;
    return {
      pools: perPool,
      totalBefore, totalMJ, afterMJ,
      coupons: couponResults, totalCoupon,
      totalAfter, totalSaved: totalBefore - totalAfter,
    };
  }

  // ---------- 凑单求解（子集和 DP）----------

  /**
   * 求解：从候选凑单品中挑组合，总价≥gap 且溢出最小（over），
   * 以及总价<gap 且最接近（under）。各返回最多 maxResults 组不同总价。
   * 候选：{name, price(分), maxQty(默认1)}。
   * 数量上限按有界背包展开；DP 上界 gap+maxPrice（最小溢出必在此窗口内：
   * 若组合溢出≥maxPrice，去掉一件仍≥gap 且更优）。
   */
  function bestFillers(gap, candidates, maxResults = 3) {
    const out = { over: [], under: [] };
    if (!candidates.length || gap <= 0) return out;

    const maxPrice = Math.max(...candidates.map((c) => c.price));
    const bound = gap + maxPrice; // 可达和上界（含）
    const reach = new Uint8Array(bound + 1);
    const cnt = new Int32Array(bound + 1).fill(Infinity); // 达到该和的最少件数
    const parentSum = new Int32Array(bound + 1).fill(-1);
    const parentIdx = new Int32Array(bound + 1).fill(-1);
    reach[0] = 1;
    cnt[0] = 0;

    // 同价候选分组，有界背包按"该价格最多用 n 件"处理会破坏路径回溯，
    // 因此仍按件展开（数量上限封顶，展开量可控）。
    for (let idx = 0; idx < candidates.length; idx++) {
      const { price, maxQty = 1 } = candidates[idx];
      if (price <= 0) continue;
      const cap = Math.max(1, Math.min(maxQty, Math.floor(bound / price)));
      // 01背包倒序 × cap 次展开该候选的每一"件"
      for (let copy = 0; copy < cap; copy++) {
        for (let s = bound; s >= price; s--) {
          if (!reach[s - price]) continue;
          const newCnt = cnt[s - price] + 1;
          if (!reach[s] || newCnt < cnt[s]) {
            reach[s] = 1;
            cnt[s] = newCnt;
            parentSum[s] = s - price;
            parentIdx[s] = idx;
          }
        }
      }
    }

    const rebuild = (sum) => {
      const counts = {};
      let s = sum;
      while (s > 0) {
        const idx = parentIdx[s];
        counts[idx] = (counts[idx] || 0) + 1;
        s = parentSum[s];
      }
      const items = Object.entries(counts).map(([idx, qty]) => ({
        name: candidates[idx].name,
        price: candidates[idx].price,
        qty,
      }));
      items.sort((a, b) => b.price * a.qty - a.price * b.qty);
      return items;
    };

    const overSums = [];
    for (let s = gap; s <= bound; s++) if (reach[s]) overSums.push(s);
    overSums.sort((a, b) => (a - gap) - (b - gap) || cnt[a] - cnt[b]);
    for (const s of overSums.slice(0, maxResults)) {
      out.over.push({ items: rebuild(s), total: s, overshoot: s - gap });
    }

    const underSums = [];
    for (let s = 1; s < gap; s++) if (reach[s]) underSums.push(s); // 排除空组合
    underSums.sort((a, b) => b - a || cnt[a] - cnt[b]);
    for (const s of underSums.slice(0, maxResults)) {
      out.under.push({ items: rebuild(s), total: s, remainGap: gap - s });
    }
    return out;
  }

  // ---------- 状态序列化（URL hash 分享）----------

  function encodeState(state) {
    const json = JSON.stringify(state);
    const b64 = (typeof btoa === 'function' ? btoa(unescape(encodeURIComponent(json)))
      : Buffer.from(json, 'utf8').toString('base64'));
    return b64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }

  function decodeState(encoded) {
    try {
      let b64 = String(encoded).replace(/-/g, '+').replace(/_/g, '/');
      while (b64.length % 4) b64 += '=';
      const json = (typeof atob === 'function' ? decodeURIComponent(escape(atob(b64)))
        : Buffer.from(b64, 'base64').toString('utf8'));
      const st = JSON.parse(json);
      if (!Array.isArray(st.pools) || !Array.isArray(st.items)) return null;
      return st;
    } catch {
      return null;
    }
  }

  return { toCents, fmt, poolSummary, cartSummary, bestFillers, encodeState, decodeState };
})();

if (typeof module !== 'undefined' && module.exports) module.exports = { MJCore };
if (typeof window !== 'undefined') window.MJCore = MJCore;
