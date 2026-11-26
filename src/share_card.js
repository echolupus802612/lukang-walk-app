/* 分享用的透卡：整張圖就是一張圓角卡片（貼文版面），使用者拍的照片只放在中間的照片格；
   狼耳小嚮導站在照片右下角，腳超出照片、落到下方，外圍是一圈虛線（像刀模貼紙）。
   版面借用社群貼文的感覺，但名稱、圖示都是自己的，不用任何平台的商標。
   renderShareCard({photo, sticker, avatar, theme, name, stop, line, place, date, nick, focusX, focusY})
   → 寬 1080、高約 1621 的 canvas，四角透明（請存成 PNG） */
(function () {
  const U = 417, ROWS = 626;                // 版面原稿的寬、高（以這組數字換算座標）
  const W = 1080, s = W / U, H = Math.round(ROWS * s);
  const THEMES = {
    pink: {bar: '#f9a8cc', barInk: '#211a1d', paper: '#ffffff', ink: '#211a1d', soft: '#5a4f54', accent: '#ec4a5a',
           avatarBg: '#2a2326', edge: 'rgba(33,26,29,.22)', dash: 'rgba(90,79,84,.75)'},
    brick: {bar: '#9a3a27', barInk: '#fbf3e6', paper: '#fbf3e6', ink: '#3a1a12', soft: '#6b4a3e', accent: '#e0a43a',
            avatarBg: '#f2c14e', edge: 'rgba(58,26,18,.25)', dash: 'rgba(107,74,62,.8)'}
  };
  const KAI = '"LXGW WenKai TC", serif', SANS = '"Noto Sans TC", sans-serif';
  const Y = v => v * s;
  const M = 5;                              // 卡片內緣留白
  const PHOTO = [122, 430];                 // 照片格的上下緣（原稿座標）

  function cover(ctx, img, x, y, w, h, fx = 0.5, fy = 0.5) {
    const r = Math.max(w / img.width, h / img.height), sw = w / r, sh = h / r;
    ctx.drawImage(img, (img.width - sw) * fx, (img.height - sh) * fy, sw, sh, x, y, w, h);
  }
  function rr(ctx, x, y, w, h, r) {        // r 可以是一個數字，或 [左上, 右上, 右下, 左下]
    const [a, b, c, d] = Array.isArray(r) ? r : [r, r, r, r];
    ctx.beginPath(); ctx.moveTo(x + a, y); ctx.arcTo(x + w, y, x + w, y + h, b); ctx.arcTo(x + w, y + h, x, y + h, c);
    ctx.arcTo(x, y + h, x, y, d); ctx.arcTo(x, y, x + w, y, a); ctx.closePath();
  }
  /* 圖示：全部自己畫的線條，不沿用任何平台的圖示 */
  const icon = {
    feet(c, x, y, z, col) {           // 兩個腳印
      c.fillStyle = col;
      for (const [dx, dy, rot] of [[-0.28, 0.12, -0.25], [0.28, -0.12, 0.25]]) {
        c.save(); c.translate(x + dx * z, y + dy * z); c.rotate(rot);
        c.beginPath(); c.ellipse(0, 0.08 * z, 0.13 * z, 0.22 * z, 0, 0, 7); c.fill();
        for (const [tx, ty, tr] of [[-0.09, -0.2, .045], [0, -0.24, .05], [0.09, -0.2, .045]]) {
          c.beginPath(); c.arc(tx * z, ty * z, tr * z, 0, 7); c.fill();
        }
        c.restore();
      }
    },
    dots(c, x, y, z, col) { c.fillStyle = col; for (const d of [-0.3, 0, 0.3]) { c.beginPath(); c.arc(x + d * z, y, 0.07 * z, 0, 7); c.fill(); } },
    heart(c, x, y, z, col, fill) {
      c.beginPath(); c.moveTo(x, y + 0.36 * z);
      c.bezierCurveTo(x - 0.62 * z, y - 0.02 * z, x - 0.38 * z, y - 0.5 * z, x, y - 0.2 * z);
      c.bezierCurveTo(x + 0.38 * z, y - 0.5 * z, x + 0.62 * z, y - 0.02 * z, x, y + 0.36 * z);
      if (fill) { c.fillStyle = col; c.fill(); } else { c.strokeStyle = col; c.stroke(); }
    },
    bubble(c, x, y, z, col) {         // 圓角對話框，尾巴在左下
      c.strokeStyle = col; rr(c, x - 0.4 * z, y - 0.34 * z, 0.8 * z, 0.6 * z, 0.22 * z); c.stroke();
      c.beginPath(); c.moveTo(x - 0.22 * z, y + 0.25 * z); c.lineTo(x - 0.3 * z, y + 0.42 * z); c.lineTo(x - 0.04 * z, y + 0.26 * z); c.stroke();
    },
    plane(c, x, y, z, col) {          // 紙飛機：簡單的折線
      c.strokeStyle = col; c.beginPath();
      c.moveTo(x - 0.4 * z, y - 0.05 * z); c.lineTo(x + 0.42 * z, y - 0.36 * z); c.lineTo(x + 0.12 * z, y + 0.4 * z);
      c.lineTo(x - 0.02 * z, y + 0.06 * z); c.closePath(); c.stroke();
      c.beginPath(); c.moveTo(x - 0.02 * z, y + 0.06 * z); c.lineTo(x + 0.42 * z, y - 0.36 * z); c.stroke();
    },
    house(c, x, y, z, col) {
      c.fillStyle = col; c.beginPath(); c.moveTo(x, y - 0.38 * z); c.lineTo(x + 0.38 * z, y - 0.02 * z); c.lineTo(x + 0.28 * z, y - 0.02 * z);
      c.lineTo(x + 0.28 * z, y + 0.36 * z); c.lineTo(x + 0.08 * z, y + 0.36 * z); c.lineTo(x + 0.08 * z, y + 0.12 * z); c.lineTo(x - 0.08 * z, y + 0.12 * z);
      c.lineTo(x - 0.08 * z, y + 0.36 * z); c.lineTo(x - 0.28 * z, y + 0.36 * z); c.lineTo(x - 0.28 * z, y - 0.02 * z); c.lineTo(x - 0.38 * z, y - 0.02 * z); c.closePath(); c.fill();
    },
    search(c, x, y, z, col) {
      c.strokeStyle = col; c.beginPath(); c.arc(x - 0.06 * z, y - 0.06 * z, 0.26 * z, 0, 7); c.stroke();
      c.beginPath(); c.moveTo(x + 0.13 * z, y + 0.13 * z); c.lineTo(x + 0.36 * z, y + 0.36 * z); c.stroke();
    },
    plus(c, x, y, z, col) {
      c.strokeStyle = col; rr(c, x - 0.36 * z, y - 0.36 * z, 0.72 * z, 0.72 * z, 0.16 * z); c.stroke();
      c.beginPath(); c.moveTo(x, y - 0.18 * z); c.lineTo(x, y + 0.18 * z); c.moveTo(x - 0.18 * z, y); c.lineTo(x + 0.18 * z, y); c.stroke();
    }
  };

  /* 刀模貼紙：角色外圍隔一段距離畫一圈虛線。先把角色輪廓往外擴，再用「行進方格」描出外框路徑 */
  function dieCut(img, frame, frames, size, gap, color, width, dash) {
    const fw = img.width / frames, pad = Math.ceil(gap + width * 2), n = size + pad * 2;
    const out = document.createElement('canvas'); out.width = out.height = n;
    const mask = document.createElement('canvas'); mask.width = mask.height = n;
    const mg = mask.getContext('2d'), sil = document.createElement('canvas'); sil.width = sil.height = size;
    const sg = sil.getContext('2d'); sg.drawImage(img, frame * fw, 0, fw, img.height, 0, 0, size, size);
    for (let a = 0; a < 36; a++) mg.drawImage(sil, pad + Math.cos(a / 36 * 6.283) * gap, pad + Math.sin(a / 36 * 6.283) * gap);
    mg.drawImage(sil, pad, pad);
    // 方格取樣：每 3 像素一格，透明度過半算在輪廓內
    const step = 3, gw = Math.floor(n / step) + 1, d = mg.getImageData(0, 0, n, n).data;
    const inside = (gx, gy) => { const x = gx * step, y = gy * step; return x >= 0 && y >= 0 && x < n && y < n && d[(y * n + x) * 4 + 3] > 128; };
    const adj = new Map(), key = (x, y) => x + ',' + y, link = (p, q) => {
      for (const [a, b] of [[p, q], [q, p]]) { const k = key(...a); (adj.get(k) || adj.set(k, []).get(k)).push(b); }
    };
    for (let gy = -1; gy < gw; gy++) for (let gx = -1; gx < gw; gx++) {
      const c0 = inside(gx, gy), c1 = inside(gx + 1, gy), c2 = inside(gx + 1, gy + 1), c3 = inside(gx, gy + 1);
      const T = [gx * 2 + 1, gy * 2], R = [gx * 2 + 2, gy * 2 + 1], B = [gx * 2 + 1, gy * 2 + 2], L = [gx * 2, gy * 2 + 1];
      const k = (c0 ? 1 : 0) | (c1 ? 2 : 0) | (c2 ? 4 : 0) | (c3 ? 8 : 0);
      const segs = {1: [[L, T]], 2: [[T, R]], 3: [[L, R]], 4: [[R, B]], 5: [[L, T], [R, B]], 6: [[T, B]], 7: [[L, B]],
                    8: [[B, L]], 9: [[T, B]], 10: [[T, R], [B, L]], 11: [[R, B]], 12: [[R, L]], 13: [[T, R]], 14: [[L, T]]}[k] || [];
      for (const [p, q] of segs) link(p, q);
    }
    const g = out.getContext('2d'); g.strokeStyle = color; g.lineWidth = width; g.lineCap = 'round'; g.setLineDash(dash);
    const seen = new Set();
    for (const start of adj.keys()) {
      if (seen.has(start)) continue;
      const loop = []; let cur = start, prev = null;
      while (cur && !seen.has(cur)) {
        seen.add(cur); const [x, y] = cur.split(',').map(Number); loop.push([x * step / 2, y * step / 2]);
        const next = (adj.get(cur) || []).map(p => key(...p)).find(k => k !== prev && !seen.has(k));
        prev = cur; cur = next;
      }
      if (loop.length < 12) continue;          // 太小的碎片不畫
      g.beginPath();
      for (let i = 0; i < loop.length; i += 2) {   // 每隔一點取一次，線條比較順
        const [x, y] = loop[i]; i ? g.lineTo(x, y) : g.moveTo(x, y);
      }
      g.closePath(); g.stroke();
    }
    g.setLineDash([]); g.drawImage(img, frame * fw, 0, fw, img.height, pad, pad, size, size);
    return {canvas: out, pad};
  }

  window.renderShareCard = function (o) {
    const t = THEMES[o.theme] || THEMES.brick;
    const cv = document.createElement('canvas'); cv.width = W; cv.height = H;
    const c = cv.getContext('2d');
    // 圓角卡片，四角透明
    rr(c, 0, 0, W, H, Y(14)); c.fillStyle = t.paper; c.fill();
    c.save(); rr(c, 0, 0, W, H, Y(14)); c.clip();
    // 上下兩條色帶（內縮一點，留出卡片邊）
    c.fillStyle = t.bar;
    rr(c, Y(M), Y(M), W - Y(2 * M), Y(55 - M), [Y(10), Y(10), 0, 0]); c.fill();
    rr(c, Y(M), Y(572), W - Y(2 * M), H - Y(572) - Y(M), [0, 0, Y(10), Y(10)]); c.fill();
    // 照片只放在中間的照片格
    cover(c, o.photo, Y(M), Y(PHOTO[0]), W - Y(2 * M), Y(PHOTO[1] - PHOTO[0]), o.focusX ?? 0.5, o.focusY ?? 0.5);

    c.lineWidth = 5; c.lineCap = 'round'; c.lineJoin = 'round';
    // 頂列：腳印、App 名稱、更多
    icon.feet(c, Y(30), Y(30), Y(30), t.barInk);
    c.fillStyle = t.barInk; c.font = `700 ${Y(24)}px ${KAI}`; c.textAlign = 'center'; c.textBaseline = 'middle';
    c.fillText('散步吧', W / 2, Y(30));
    icon.dots(c, W - Y(32), Y(30), Y(30), t.barInk);
    // 頭像與暱稱
    const av = Y(34), ax = Y(38), ay = Y(88);
    c.save(); c.beginPath(); c.arc(ax, ay, av / 2, 0, 7); c.fillStyle = t.avatarBg; c.fill(); c.clip();
    const fw = o.avatar.width / 4;            // 待機動作第一格，只取頭部
    c.drawImage(o.avatar, fw * 0.28, o.avatar.height * 0.06, fw * 0.44, fw * 0.44, ax - av * 0.62, ay - av * 0.55, av * 1.24, av * 1.24);
    c.restore();
    c.fillStyle = t.ink; c.font = `700 ${Y(15)}px ${SANS}`; c.textAlign = 'left';
    c.fillText(o.nick || '散步吧・小嚮導', Y(64), ay);
    // 分頁小點
    for (let i = 0; i < 5; i++) { c.beginPath(); c.arc(W / 2 + (i - 2) * Y(9), Y(441), Y(2.3), 0, 7); c.fillStyle = i === 1 ? t.accent : 'rgba(58,26,18,.22)'; c.fill(); }
    // 動作列
    c.lineWidth = Y(2.4);
    icon.heart(c, Y(34), Y(476), Y(30), t.accent, true);
    icon.bubble(c, Y(82), Y(475), Y(30), t.ink);
    icon.plane(c, Y(129), Y(475), Y(30), t.ink);
    // 文字：距離、地名＋第幾站、地點與日期
    c.fillStyle = t.ink; c.textBaseline = 'alphabetic';
    c.font = `700 ${Y(14)}px ${SANS}`; c.fillText(o.line, Y(22), Y(518));
    c.font = `500 ${Y(16)}px ${KAI}`;
    c.fillText(o.stop == null ? o.name : `${o.name}・第 ${o.stop} 站`, Y(22), Y(542));
    c.fillStyle = t.soft; c.font = `500 ${Y(11)}px ${SANS}`; c.fillText([o.place,o.date].filter(Boolean).join('　'), Y(22), Y(563));
    // 底列四個圖示，平均排開
    c.lineWidth = Y(2.2);
    const navY = Y(599);
    icon.house(c, W * 0.125, navY, Y(32), t.barInk);
    icon.search(c, W * 0.375, navY, Y(32), t.barInk);
    icon.plus(c, W * 0.625, navY, Y(32), t.barInk);
    icon.heart(c, W * 0.875, navY, Y(30), t.barInk, false);
    // 小嚮導：站在照片右下角，腳落到照片下方
    const size = Math.round(Y(196)), cut = dieCut(o.sticker, o.frame ?? 1, 4, size, Y(7), t.dash, Y(1.4), [Y(3.2), Y(3.2)]);
    c.drawImage(cut.canvas, Y(244) - cut.pad, Y(322) - cut.pad);
    // 透卡的反光：一道很淡的斜光
    const g = c.createLinearGradient(0, 0, W, H);
    g.addColorStop(0.4, 'rgba(255,255,255,0)'); g.addColorStop(0.5, 'rgba(255,255,255,.1)'); g.addColorStop(0.6, 'rgba(255,255,255,0)');
    c.fillStyle = g; c.fillRect(0, 0, W, H);
    c.restore();
    // 卡片外框細線
    c.strokeStyle = t.edge; c.lineWidth = Y(1); rr(c, Y(0.5), Y(0.5), W - Y(1), H - Y(1), Y(14)); c.stroke();
    return cv;
  };
})();
