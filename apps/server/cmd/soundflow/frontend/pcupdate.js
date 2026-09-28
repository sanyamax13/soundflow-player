/* Обновление программы на компьютере (pcupdate.go, 28.09.2026): вышла новая версия — в шапке окна
   лаймовая кнопка «Обновить до X». Нажали — программа скачивает установщик и ставит его тихо;
   окно закроется и откроется уже новой версией. Настройки и база не трогаются. */
(function(){
  const sp = document.querySelector(".top .sp");
  if(!sp) return;
  const btn = document.createElement("button");
  btn.type = "button";
  btn.className = "btn primary";
  btn.style.cssText = "margin-right:12px; display:none";
  sp.after(btn);
  async function check(){
    try {
      const r = await fetch("/api/pc-update"); if(!r.ok) return;
      const u = await r.json();
      if(u.available){ btn.textContent = "Обновить до " + u.latest; btn.title = u.changelog || ""; btn.style.display = ""; }
    } catch(e){}
  }
  btn.onclick = async () => {
    btn.disabled = true; btn.textContent = "Скачиваю обновление…";
    try {
      const r = await fetch("/api/pc-update", {method: "POST"});
      if(!r.ok) throw new Error((await r.text()).trim());
      btn.textContent = "Устанавливаю — окно перезапустится само";
    } catch(e){ btn.disabled = false; btn.textContent = "Не вышло: " + e.message; }
  };
  check();
  setInterval(check, 6 * 3600 * 1000);
})();
