// dump_classes.js — 枚举三家地图里的广告类 + 自身广告方法
// 用法: frida -U -n "高德地图" -l re/dump_classes.js
//
// 输出: 每个命中类的 $ownMethods 里形如 loadAd/show/present/request 的 selector，
//       抄进 Tweak.xm 的 installTargetedHooks() 数组: @[ClassName, selectorName]

const TOKENS = [
  "Splash", "Banner", "Ad", "AD", "GDT", "CSJ", "Pangle", "KSAd", "BUAd", "BUN",
  "Meridian", "GroMore", "AnyThink", "Sigmob", "Beizi", "Qumeng", "Meishu",
  "Unity", "Reward", "Interstitial", "Feed", "Native", "Octopus"
];

function scan() {
  const out = [];
  const classes = ObjC.classes;
  for (const name of Object.keys(classes)) {
    if (name.startsWith("UI") || name.startsWith("NS") ||
        name.startsWith("CA") || name.startsWith("_")) continue;
    if (!TOKENS.some(t => name.includes(t))) continue;
    const cls = classes[name];
    const methods = [];
    try {
      // $ownMethods = 仅本类声明的方法（等价于 Android "只挂 SDK 自身方法"）
      for (const m of cls.$ownMethods) {
        if (/ad|splash|banner|load|show|present|request|fetch|render|display/i.test(m)) {
          methods.push(m);
        }
      }
    } catch (e) { /* ignore */ }
    if (methods.length > 0) out.push({ cls: name, methods });
  }
  return out;
}

const res = scan();
console.log("AD-CLASS COUNT:", res.length);
for (const r of res) {
  console.log("== " + r.cls);
  for (const m of r.methods) console.log("   - " + m);
}
