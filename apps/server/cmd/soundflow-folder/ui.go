package main

import (
	"github.com/lxn/walk"
)

// Тёмный вид в духе ФармМастера (Alex TG 18729): весь экран рисуем сами на
// одном CustomWidget — так native-кнопки Win32 не портят тёмную тему.

var (
	cBg     = walk.RGB(0x14, 0x17, 0x1C)
	cBar    = walk.RGB(0x0F, 0x12, 0x16)
	cField  = walk.RGB(0x23, 0x28, 0x30)
	cInk    = walk.RGB(0xE7, 0xEA, 0xEF)
	cMut    = walk.RGB(0x8A, 0x94, 0xA1)
	cFaint  = walk.RGB(0x6C, 0x76, 0x83)
	cAccent = walk.RGB(0x3E, 0x5F, 0xE0)
	cAccHi  = walk.RGB(0x5B, 0x79, 0xF0)
	cStroke = walk.RGB(0x39, 0x42, 0x4E)
	cOk     = walk.RGB(0x3F, 0xB9, 0x50)
	cErr    = walk.RGB(0xF8, 0x51, 0x49)
	cWhite  = walk.RGB(0xFF, 0xFF, 0xFF)
)

type ui struct {
	cw *walk.CustomWidget

	folder string
	count  int
	addr   string
	status string
	phase  int // 0 ждём, 1 читаю, 2 работает, 3 ошибка

	darkDone bool
	hover    int // -1 нет, 0 «выбрать», 1 «запустить», 2 адрес
	rPick    walk.Rectangle
	rGo      walk.Rectangle
	rAddr    walk.Rectangle

	// кэш ресурсов (живут всё время работы)
	brBg, brBar, brField, brAccent, brAccHi, brIcon *walk.SolidColorBrush
	penStroke, penAccent                            walk.Pen
	fTitle, fLabel, fBody, fAddr, fHint, fIcon      *walk.Font
}

func newUI() *ui {
	return &ui{phase: 0, hover: -1, status: "Выбери папку и нажми «Запустить раздачу»."}
}

func (u *ui) ensureRes() {
	if u.brBg != nil {
		return
	}
	u.brBg, _ = walk.NewSolidColorBrush(cBg)
	u.brBar, _ = walk.NewSolidColorBrush(cBar)
	u.brField, _ = walk.NewSolidColorBrush(cField)
	u.brAccent, _ = walk.NewSolidColorBrush(cAccent)
	u.brAccHi, _ = walk.NewSolidColorBrush(cAccHi)
	u.brIcon, _ = walk.NewSolidColorBrush(cAccent)
	if p, err := walk.NewCosmeticPen(walk.PenSolid, cStroke); err == nil {
		u.penStroke = p
	}
	if p, err := walk.NewCosmeticPen(walk.PenSolid, cAccent); err == nil {
		u.penAccent = p
	}
	u.fTitle, _ = walk.NewFont("Segoe UI", 12, walk.FontBold)
	u.fLabel, _ = walk.NewFont("Segoe UI", 9, 0)
	u.fBody, _ = walk.NewFont("Segoe UI", 10, 0)
	u.fAddr, _ = walk.NewFont("Segoe UI", 13, walk.FontBold)
	u.fHint, _ = walk.NewFont("Segoe UI", 8, 0)
	u.fIcon, _ = walk.NewFont("Segoe UI", 12, walk.FontBold)
}

func (u *ui) redraw() {
	if u.cw != nil {
		u.cw.Invalidate()
	}
}

// --- состояние снаружи ---

func (u *ui) setFolder(s string) { u.folder = s; u.redraw() }
func (u *ui) setBusy() {
	u.phase = 1
	u.status = "Читаю песни…"
	u.count = 0
	u.addr = ""
	u.redraw()
}
func (u *ui) setScanProgress(n int) {
	u.count = n
	u.status = "Читаю песни… " + itoa(n)
	u.redraw()
}
func (u *ui) setRunning(count int, addr string) {
	u.phase = 2
	u.count = count
	u.addr = addr
	u.status = "Работает. Раздаю музыку — можно качать на телефон."
	u.redraw()
}
func (u *ui) setError(msg string)  { u.phase = 3; u.status = msg; u.redraw() }
func (u *ui) setStatus(msg string) { u.status = msg; u.redraw() }

// --- отрисовка ---

const (
	padX = 20
	barH = 54
)

func (u *ui) paint(canvas *walk.Canvas, _ walk.Rectangle) error {
	u.ensureRes()
	if !u.darkDone && mw != nil {
		u.darkDone = true
		darkTitleBar(uintptr(mw.Handle()))
	}
	W := u.cw.ClientBounds().Width

	rc := func(x, y, w, h int) walk.Rectangle { return walk.Rectangle{X: x, Y: y, Width: w, Height: h} }
	full := rc(0, 0, W, 1000)
	canvas.FillRectangle(u.brBg, full)

	// шапка
	canvas.FillRectangle(u.brBar, rc(0, 0, W, barH))
	canvas.DrawLine(u.penStroke, walk.Point{X: 0, Y: barH}, walk.Point{X: W, Y: barH})
	canvas.FillRoundedRectangle(u.brIcon, rc(padX, 11, 32, 32), walk.Size{Width: 10, Height: 10})
	canvas.DrawText("SF", u.fIcon, cWhite, rc(padX, 10, 32, 32), walk.TextCenter|walk.TextVCenter|walk.TextSingleLine)
	canvas.DrawText("SoundFlow — раздача музыки тестировщику", u.fTitle, cInk,
		rc(padX+44, 0, W-padX-44, barH), walk.TextLeft|walk.TextVCenter|walk.TextSingleLine|walk.TextEndEllipsis)

	y := barH + 20

	// 1. папка
	canvas.DrawText("1. Папка со своей музыкой (можно на любом диске):", u.fLabel, cMut,
		rc(padX, y, W-2*padX, 18), walk.TextLeft|walk.TextSingleLine)
	y += 22
	fw := W - 2*padX
	canvas.FillRectangle(u.brField, rc(padX, y, fw, 30))
	canvas.DrawRectangle(u.penStroke, rc(padX, y, fw, 30))
	pathTxt, pathCol := u.folder, cInk
	if pathTxt == "" {
		pathTxt, pathCol = "папка не выбрана", cFaint
	}
	canvas.DrawText(pathTxt, u.fBody, pathCol, rc(padX+10, y, fw-20, 30),
		walk.TextLeft|walk.TextVCenter|walk.TextSingleLine|walk.TextPathEllipsis)
	y += 40

	// кнопка «Выбрать папку…» — вторичная
	u.rPick = rc(padX, y, 200, 32)
	u.drawBtn(canvas, u.rPick, "Выбрать папку…", false, u.hover == 0)
	y += 44

	// кнопка «Запустить раздачу» — главная
	u.rGo = rc(padX, y, fw, 40)
	goText := "2. Запустить раздачу"
	if u.phase == 1 {
		goText = "Читаю песни…"
	}
	u.drawBtn(canvas, u.rGo, goText, true, u.hover == 1 && u.phase != 1)
	y += 50

	// счётчик
	if u.phase >= 2 {
		canvas.DrawText("Готово к раздаче: "+itoa(u.count)+" "+songWord(u.count), u.fBody, cInk,
			rc(padX, y, fw, 20), walk.TextLeft|walk.TextSingleLine)
	}
	y += 24

	// 2. адрес
	canvas.DrawText("Адрес для телефона — впиши в SoundFlow, потом «докачать всё»:", u.fLabel, cMut,
		rc(padX, y, fw, 18), walk.TextLeft|walk.TextSingleLine)
	y += 20
	u.rAddr = rc(padX, y, fw, 36)
	canvas.FillRectangle(u.brField, u.rAddr)
	if u.hover == 2 && u.addr != "" {
		canvas.DrawRectangle(u.penAccent, u.rAddr)
	} else {
		canvas.DrawRectangle(u.penStroke, u.rAddr)
	}
	addrTxt, addrCol := u.addr, cAccHi
	if addrTxt == "" {
		addrTxt, addrCol = "—", cFaint
	}
	canvas.DrawText(addrTxt, u.fAddr, addrCol, u.rAddr, walk.TextCenter|walk.TextVCenter|walk.TextSingleLine)
	y += 44

	// статус
	sc := cMut
	switch u.phase {
	case 2:
		sc = cOk
	case 3:
		sc = cErr
	}
	canvas.DrawText(u.status, u.fBody, sc, rc(padX, y, fw, 20), walk.TextLeft|walk.TextSingleLine|walk.TextEndEllipsis)

	// подсказка снизу
	canvas.DrawText("Телефон и этот компьютер — в одной Wi-Fi. Окно не закрывать, пока телефон качает.",
		u.fHint, cFaint, rc(padX, u.cw.ClientBounds().Height-26, fw, 18), walk.TextLeft|walk.TextSingleLine)
	return nil
}

func (u *ui) drawBtn(canvas *walk.Canvas, r walk.Rectangle, text string, primary, hover bool) {
	if primary {
		br := u.brAccent
		if hover {
			br = u.brAccHi
		}
		canvas.FillRoundedRectangle(br, r, walk.Size{Width: 8, Height: 8})
		canvas.DrawText(text, u.fBody, cWhite, r, walk.TextCenter|walk.TextVCenter|walk.TextSingleLine)
		return
	}
	canvas.FillRoundedRectangle(u.brField, r, walk.Size{Width: 8, Height: 8})
	pen := u.penStroke
	if hover {
		pen = u.penAccent
	}
	canvas.DrawRoundedRectangle(pen, r, walk.Size{Width: 8, Height: 8})
	canvas.DrawText(text, u.fBody, cInk, r, walk.TextCenter|walk.TextVCenter|walk.TextSingleLine)
}

func hit(r walk.Rectangle, x, y int) bool {
	return x >= r.X && x < r.X+r.Width && y >= r.Y && y < r.Y+r.Height
}

func (u *ui) onMouseDown(x, y int, _ walk.MouseButton) {
	switch {
	case hit(u.rPick, x, y):
		onPick()
	case u.phase != 1 && hit(u.rGo, x, y):
		onStart()
	case u.addr != "" && hit(u.rAddr, x, y):
		if cb := walk.Clipboard(); cb != nil {
			_ = cb.SetText(u.addr)
			u.setStatus("Адрес скопирован — вставь в SoundFlow на телефоне.")
		}
	}
}

func (u *ui) onMouseMove(x, y int, _ walk.MouseButton) {
	h := -1
	switch {
	case hit(u.rPick, x, y):
		h = 0
	case u.phase != 1 && hit(u.rGo, x, y):
		h = 1
	case u.addr != "" && hit(u.rAddr, x, y):
		h = 2
	}
	if h != u.hover {
		u.hover = h
		if h >= 0 {
			u.cw.SetCursor(walk.CursorHand())
		} else {
			u.cw.SetCursor(walk.CursorArrow())
		}
		u.redraw()
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}

func songWord(n int) string {
	m10, m100 := n%10, n%100
	switch {
	case m10 == 1 && m100 != 11:
		return "песня"
	case m10 >= 2 && m10 <= 4 && (m100 < 10 || m100 >= 20):
		return "песни"
	default:
		return "песен"
	}
}
