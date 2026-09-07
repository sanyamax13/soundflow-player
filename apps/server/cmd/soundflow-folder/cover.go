package main

import (
	"bytes"
	"crypto/sha1"
	"image"
	"image/color"
	"image/png"
	"math"
	"sync"
)

// Обложка-заглушка, когда в файле картинки нет (Alex TG 18725): абстрактный
// узор в тёмно-зелёной гамме приложения, цвет пятен зависит от названия —
// у разных песен разный. Считаем один раз на id и держим в памяти.
var (
	coverMu    sync.Mutex
	coverCache = map[string][]byte{}
)

func generatedCover(seed string) []byte {
	coverMu.Lock()
	if b, ok := coverCache[seed]; ok {
		coverMu.Unlock()
		return b
	}
	coverMu.Unlock()

	const s = 400
	h := sha1.Sum([]byte(seed))
	hue := float64(h[0]) / 255 * 360
	img := image.NewRGBA(image.Rect(0, 0, s, s))

	bg := color.RGBA{0x0e, 0x15, 0x12, 0xff}
	for y := 0; y < s; y++ {
		for x := 0; x < s; x++ {
			img.Set(x, y, bg)
		}
	}

	blobs := []struct {
		cx, cy, r float64
		hueOff, a float64
	}{
		{float64(h[1]) / 255 * s, float64(h[2]) / 255 * s, 150 + float64(h[3])/255*120, 0, 0.35},
		{float64(h[4]) / 255 * s, float64(h[5]) / 255 * s, 90 + float64(h[6])/255*90, 40, 0.30},
		{float64(h[7]) / 255 * s, float64(h[8]) / 255 * s, 50 + float64(h[9])/255*60, -30, 0.40},
	}
	for _, b := range blobs {
		cr, cg, cb := hsv(math.Mod(hue+b.hueOff+360, 360), 0.55, 0.75)
		for y := 0; y < s; y++ {
			for x := 0; x < s; x++ {
				dx, dy := float64(x)-b.cx, float64(y)-b.cy
				if dx*dx+dy*dy > b.r*b.r {
					continue
				}
				o := img.RGBAAt(x, y)
				img.SetRGBA(x, y, color.RGBA{
					R: mix(o.R, cr, b.a),
					G: mix(o.G, cg, b.a),
					B: mix(o.B, cb, b.a),
					A: 0xff,
				})
			}
		}
	}

	var buf bytes.Buffer
	_ = png.Encode(&buf, img)
	out := buf.Bytes()
	coverMu.Lock()
	coverCache[seed] = out
	coverMu.Unlock()
	return out
}

func mix(a, b uint8, t float64) uint8 {
	return uint8(float64(a)*(1-t) + float64(b)*t)
}

func hsv(h, s, v float64) (uint8, uint8, uint8) {
	c := v * s
	x := c * (1 - math.Abs(math.Mod(h/60, 2)-1))
	m := v - c
	var r, g, b float64
	switch {
	case h < 60:
		r, g, b = c, x, 0
	case h < 120:
		r, g, b = x, c, 0
	case h < 180:
		r, g, b = 0, c, x
	case h < 240:
		r, g, b = 0, x, c
	case h < 300:
		r, g, b = x, 0, c
	default:
		r, g, b = c, 0, x
	}
	return uint8((r + m) * 255), uint8((g + m) * 255), uint8((b + m) * 255)
}
