package coverfind

import (
	"bytes"
	"errors"
	"image"
	"image/color"
	"image/draw"
	"image/jpeg"
	_ "image/png" // декодер PNG для image.Decode
)

// minImageBytes — картинки меньше этого — заглушки/иконки, не обложки.
const minImageBytes = 4000

// PrepareJPEG — проверить, что это настоящая картинка (JPEG/PNG, не заглушка),
// при необходимости уменьшить так, чтобы длинная сторона была не больше maxPx, и
// вернуть JPEG качества 85. Обложка на телефон не должна весить мегабайты, а
// 600 px хватает на самый большой экран плеера.
func PrepareJPEG(body []byte, maxPx int) ([]byte, error) {
	if len(body) < minImageBytes {
		return nil, errors.New("слишком маленький файл — это не обложка")
	}
	isJPEG := bytes.HasPrefix(body, []byte{0xff, 0xd8, 0xff})
	isPNG := bytes.HasPrefix(body, []byte("\x89PNG\r\n\x1a\n"))
	if !isJPEG && !isPNG {
		return nil, errors.New("не JPEG и не PNG")
	}
	img, _, err := image.Decode(bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	b := img.Bounds()
	if b.Dx() < 100 || b.Dy() < 100 {
		return nil, errors.New("картинка меньше 100 px")
	}
	if isJPEG && b.Dx() <= maxPx && b.Dy() <= maxPx {
		return body, nil // уже подходящий JPEG — не перекодируем, не теряем качество
	}
	out := shrink(img, maxPx)
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, out, &jpeg.Options{Quality: 85}); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// shrink — уменьшить до maxPx по длинной стороне усреднением по площади (для
// уменьшения это лучше, чем выбор ближайшей точки). Меньше — вернуть как есть
// (на белом фоне, чтобы прозрачность PNG не стала чёрной).
func shrink(src image.Image, maxPx int) image.Image {
	b := src.Bounds()
	w, h := b.Dx(), b.Dy()
	nw, nh := w, h
	if w > maxPx || h > maxPx {
		if w >= h {
			nw, nh = maxPx, h*maxPx/w
		} else {
			nw, nh = w*maxPx/h, maxPx
		}
		if nh < 1 {
			nh = 1
		}
		if nw < 1 {
			nw = 1
		}
	}
	flat := image.NewRGBA(b)
	draw.Draw(flat, b, image.NewUniform(color.White), image.Point{}, draw.Src)
	draw.Draw(flat, b, src, b.Min, draw.Over)
	if nw == w && nh == h {
		return flat
	}
	dst := image.NewRGBA(image.Rect(0, 0, nw, nh))
	for y := 0; y < nh; y++ {
		y0, y1 := b.Min.Y+y*h/nh, b.Min.Y+(y+1)*h/nh
		if y1 <= y0 {
			y1 = y0 + 1
		}
		for x := 0; x < nw; x++ {
			x0, x1 := b.Min.X+x*w/nw, b.Min.X+(x+1)*w/nw
			if x1 <= x0 {
				x1 = x0 + 1
			}
			var r, g, bl, n uint32
			for yy := y0; yy < y1; yy++ {
				for xx := x0; xx < x1; xx++ {
					c := flat.RGBAAt(xx, yy)
					r += uint32(c.R)
					g += uint32(c.G)
					bl += uint32(c.B)
					n++
				}
			}
			dst.SetRGBA(x, y, color.RGBA{uint8(r / n), uint8(g / n), uint8(bl / n), 255})
		}
	}
	return dst
}
