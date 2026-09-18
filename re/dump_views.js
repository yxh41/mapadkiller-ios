// dump_views.js — 打印 keyWindow 的 UIView 树（类名 / accessibilityLabel / hidden / frame）
// 用法: frida -U -n "高德地图" -l re/dump_views.js
// 在开屏广告 / 首页 banner 出现时跑，找带 Ad/Banner/Splash 的 view 类名，
// 抄进 Tweak.xm 的 adNameMatch token（或靠视图清扫直接命中）。

function keyWindow() {
  const app = ObjC.classes.UIApplication.sharedApplication();
  const scenes = app.connectedScenes().allObjects();
  for (const sc of scenes) {
    if (sc.isKindOfClass_(ObjC.classes.UIWindowScene)) {
      const windows = sc.windows();
      for (const w of windows) {
        if (w.isKeyWindow && w.isKeyWindow()) return w;
      }
    }
  }
  return null;
}

function dumpView(v, depth) {
  if (!v) return;
  const pad = "  ".repeat(depth);
  const cls = v.$className;
  let label = "";
  try { label = v.accessibilityLabel ? (v.accessibilityLabel() || "") : ""; } catch (e) {}
  let id = "";
  try { id = v.accessibilityIdentifier ? (v.accessibilityIdentifier() || "") : ""; } catch (e) {}
  let hidden = false;
  try { hidden = v.hidden ? !!v.hidden() : false; } catch (e) {}
  let frame = "";
  try { const f = v.frame(); frame = `(${f.x},${f.y},${f.width},${f.height})`; } catch (e) {}
  console.log(`${pad}${cls} label="${label}" id="${id}" hidden=${hidden} frame=${frame}`);
  let subs = [];
  try { subs = v.subviews ? v.subviews() : []; } catch (e) {}
  for (const s of subs) dumpView(s, depth + 1);
}

const win = keyWindow();
if (win) {
  console.log("KEY WINDOW:", win.$className);
  dumpView(win, 0);
} else {
  console.log("no key window found");
}
