package localdb

import (
	"encoding/binary"
	"math"
	"strconv"
	"strings"
)

// VecDim — размерность звукового отпечатка PANNs CNN14.
const VecDim = 2048

// vecToBlob — []float32 → BLOB (little-endian float32). nil → nil (в БД NULL).
func vecToBlob(v []float32) []byte {
	if len(v) == 0 {
		return nil
	}
	b := make([]byte, len(v)*4)
	for i, f := range v {
		binary.LittleEndian.PutUint32(b[i*4:], math.Float32bits(f))
	}
	return b
}

// VecToBlob — экспортируемая обёртка vecToBlob, для кода вне пакета (HTTP-ручки).
func VecToBlob(v []float32) []byte { return vecToBlob(v) }

// blobToVec — BLOB → []float32. Пустой/битой длины → nil.
func blobToVec(b []byte) []float32 {
	if len(b) == 0 || len(b)%4 != 0 {
		return nil
	}
	v := make([]float32, len(b)/4)
	for i := range v {
		v[i] = math.Float32frombits(binary.LittleEndian.Uint32(b[i*4:]))
	}
	return v
}

// parsePgVector — pgvector-текст "[0.1,0.2,...]" → []float32. Пусто → nil.
func parsePgVector(s string) []float32 {
	s = strings.TrimSpace(s)
	s = strings.TrimPrefix(s, "[")
	s = strings.TrimSuffix(s, "]")
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	v := make([]float32, 0, len(parts))
	for _, p := range parts {
		f, err := strconv.ParseFloat(strings.TrimSpace(p), 32)
		if err != nil {
			return nil
		}
		v = append(v, float32(f))
	}
	return v
}

// cosine — косинусная близость двух векторов (0 при нулевой норме).
func cosine(a, b []float32) float64 {
	if len(a) == 0 || len(a) != len(b) {
		return 0
	}
	var dot, na, nb float64
	for i := range a {
		dot += float64(a[i]) * float64(b[i])
		na += float64(a[i]) * float64(a[i])
		nb += float64(b[i]) * float64(b[i])
	}
	if na == 0 || nb == 0 {
		return 0
	}
	return dot / (math.Sqrt(na) * math.Sqrt(nb))
}
