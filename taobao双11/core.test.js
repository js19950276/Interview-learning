'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { MJCore } = require('./core.js');

// ---------- toCents / fmt ----------
test('toCents 基本转换', () => {
  assert.strictEqual(MJCore.toCents('89'), 8900);
  assert.strictEqual(MJCore.toCents('89.5'), 8950);
  assert.strictEqual(MJCore.toCents('89.55'), 8955);
  assert.strictEqual(MJCore.toCents('1,299.00'), 129900);
  assert.strictEqual(MJCore.toCents(12.34), 1234);
  assert.strictEqual(MJCore.toCents(' 9.9 '), 990);
});

test('toCents 非法输入抛错', () => {
  for (const bad of ['abc', '-5', '', '12.345', '1.2.3', undefined, NaN]) {
    assert.throws(() => MJCore.toCents(bad), /价格/);
  }
});

test('fmt 输出两位小数', () => {
  assert.strictEqual(MJCore.fmt(8900), '89.00');
  assert.strictEqual(MJCore.fmt(995), '9.95');
  assert.strictEqual(MJCore.fmt(0), '0.00');
});

// ---------- poolSummary ----------
const P300 = { id: 'p1', name: '跨店满减', per: 30000, off: 5000 };
const it = (id, name, price, poolId, qty = 1) => ({ id, name, price, poolId, qty });

test('poolSummary 610 元：2 档减 100，差 290 到下一档(900)', () => {
  const s = MJCore.poolSummary([it('a', 'A', 30000, 'p1'), it('b', 'B', 31000, 'p1')], P300);
  assert.strictEqual(s.subtotal, 61000);
  assert.strictEqual(s.tiers, 2);
  assert.strictEqual(s.discount, 10000);
  assert.strictEqual(s.gap, 29000);
  assert.strictEqual(s.effective, 51000);
});

test('poolSummary 恰好 600：下一档需再加 300', () => {
  const s = MJCore.poolSummary([it('a', 'A', 30000, 'p1'), it('b', 'B', 30000, 'p1')], P300);
  assert.strictEqual(s.tiers, 2);
  assert.strictEqual(s.discount, 10000);
  assert.strictEqual(s.gap, 30000);
});

test('poolSummary 空池：gap 为整档', () => {
  const s = MJCore.poolSummary([], P300);
  assert.strictEqual(s.subtotal, 0);
  assert.strictEqual(s.tiers, 0);
  assert.strictEqual(s.discount, 0);
  assert.strictEqual(s.gap, 30000);
});

test('poolSummary 差一分到门槛', () => {
  const s = MJCore.poolSummary([it('a', 'A', 29999, 'p1')], P300);
  assert.strictEqual(s.tiers, 0);
  assert.strictEqual(s.gap, 1);
});

test('poolSummary 只统计本池商品，且尊重数量', () => {
  const items = [it('a', 'A', 10000, 'p1', 2), it('b', 'B', 99999, 'other')];
  const s = MJCore.poolSummary(items, P300);
  assert.strictEqual(s.subtotal, 20000);
});

// ---------- cartSummary + 券 ----------
test('cartSummary 汇总多池与整单券', () => {
  const pools = [P300, { id: 'p2', name: '生鲜池', per: 20000, off: 3000 }];
  const items = [
    it('a', 'A', 61000, 'p1'),
    it('b', 'B', 25000, 'p2'),
  ];
  const coupons = [{ id: 'c1', name: '官方消费券', min: 100000, off: 12000 }];
  const r = MJCore.cartSummary(items, pools, coupons);
  // 池1: 610 -> 减100；池2: 250 -> 减30
  assert.strictEqual(r.totalBefore, 86000);
  assert.strictEqual(r.totalMJ, 13000);
  assert.strictEqual(r.afterMJ, 73000);
  // 券门槛 1000 > 730 -> 未达标，差 270
  assert.strictEqual(r.coupons.length, 1);
  assert.strictEqual(r.coupons[0].ok, false);
  assert.strictEqual(r.coupons[0].gap, 27000);
  assert.strictEqual(r.totalCoupon, 0);
  assert.strictEqual(r.totalAfter, 73000);
  assert.strictEqual(r.totalSaved, 13000);
});

test('cartSummary 券达标后计入实付与已省', () => {
  const items = [it('a', 'A', 100000, 'p1')];
  const coupons = [{ id: 'c1', name: '券', min: 100000, off: 12000 }];
  const r = MJCore.cartSummary(items, [P300], coupons);
  assert.strictEqual(r.afterMJ, 85000); // 1000 - 150(3档×50)
  assert.strictEqual(r.coupons[0].ok, false); // 门槛按满减后价：850 < 1000
  // 再加一件 300：1300 元 4 档减 200 -> 1100，券达标
  const items2 = [...items, it('b', 'B', 30000, 'p1')];
  const r2 = MJCore.cartSummary(items2, [P300], coupons);
  assert.strictEqual(r2.afterMJ, 110000);
  assert.strictEqual(r2.coupons[0].ok, true);
  // 再加 400：1700 元 5 档减 250 -> 1450，券再减 120 -> 实付 1330
  const items3 = [...items2, it('c', 'C', 40000, 'p1')];
  const r3 = MJCore.cartSummary(items3, [P300], coupons);
  assert.strictEqual(r3.afterMJ, 145000);
  assert.strictEqual(r3.totalCoupon, 12000);
  assert.strictEqual(r3.totalAfter, 133000);
  assert.strictEqual(r3.totalSaved, 37000);
});

// ---------- bestFillers 凑单求解 ----------
const f = (name, price, maxQty) => ({ name, price, maxQty });

test('bestFillers：两件组合越线且不越线最优', () => {
  const r = MJCore.bestFillers(10000, [f('x', 6000, 1), f('y', 5000, 1)]);
  assert.strictEqual(r.over.length, 1);
  assert.strictEqual(r.over[0].total, 11000);
  assert.strictEqual(r.over[0].overshoot, 1000);
  assert.strictEqual(r.under.length, 2); // 60 和 50 都给出来
  assert.strictEqual(r.under[0].total, 6000);
});

test('bestFillers：恰好凑齐溢出为 0', () => {
  const r = MJCore.bestFillers(10000, [f('x', 10000, 1)]);
  assert.strictEqual(r.over[0].overshoot, 0);
});

test('bestFillers：全部不够时 over 为空，under 给最接近组合', () => {
  const r = MJCore.bestFillers(10000, [f('a', 4000, 1), f('b', 4000, 1)]);
  assert.strictEqual(r.over.length, 0);
  assert.strictEqual(r.under[0].total, 8000);
});

test('bestFillers：数量上限生效', () => {
  const r = MJCore.bestFillers(10000, [f('袜子', 3000, 4)]);
  assert.strictEqual(r.over[0].total, 12000); // 4双=120 溢出20
  assert.strictEqual(r.over[0].items[0].qty, 4);
  assert.strictEqual(r.under[0].total, 9000); // 3双=90
});

test('bestFillers：最小溢出可能来自组合而非单件', () => {
  // gap=100；单件 119 溢出 19；组合 89+9.9=98.9<100 不行；89+19.9=108.9 溢出 8.9 更优
  const r = MJCore.bestFillers(10000, [f('大', 11900, 1), f('中', 8900, 1), f('小', 1990, 1)]);
  assert.strictEqual(r.over[0].overshoot, 890);
  assert.strictEqual(r.over[0].total, 10890);
});

test('bestFillers：空候选返回空结果', () => {
  const r = MJCore.bestFillers(10000, []);
  assert.deepStrictEqual(r, { over: [], under: [] });
});

test('bestFillers：候选全部远大于 gap 时给最小溢出单件', () => {
  const r = MJCore.bestFillers(1000, [f('x', 10000, 1), f('y', 20000, 1)]);
  assert.strictEqual(r.over.length, 2); // 100 和 200 都越线，按溢出升序
  assert.strictEqual(r.over[0].total, 10000);
  assert.strictEqual(r.under.length, 0);
});

test('bestFillers：over 结果按溢出升序且最多 3 组不同总价', () => {
  const cands = [990, 1990, 2990, 3990, 5900, 6900, 8900, 9900, 11900].map((p, i) => f('件' + i, p, 1));
  const r = MJCore.bestFillers(9000, cands);
  assert.ok(r.over.length >= 1 && r.over.length <= 3);
  for (let i = 1; i < r.over.length; i++) {
    assert.ok(r.over[i].oversoot === undefined || r.over[i].overshoot >= r.over[i - 1].overshoot);
    assert.ok(r.over[i].total > r.over[i - 1].total);
  }
  assert.ok(r.over[0].total >= 9000);
});

// ---------- 状态序列化 ----------
test('encodeState/decodeState 往返一致', () => {
  const state = {
    pools: [P300],
    items: [it('a', '面霜', 58000, 'p1', 2)],
    coupons: [{ id: 'c1', name: '券', min: 100000, off: 12000 }],
    fillers: [{ id: 'f1', name: '袜子', price: 2990 }],
  };
  const hash = MJCore.encodeState(state);
  assert.ok(!hash.includes('{'));
  assert.deepStrictEqual(MJCore.decodeState(hash), state);
});

test('decodeState 非法输入返回 null', () => {
  assert.strictEqual(MJCore.decodeState('%%%not-base64%%%'), null);
});
