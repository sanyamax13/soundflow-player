package quality

import (
	"fmt"
	"path/filepath"
	"strings"
)

// Codec-aware оценка качества файла. Перенос audio-quality.ts: универсальный
// порог «bitrate < 96» груб (mp3 128 хуже AAC 128, Opus 128 ~ mp3 192).

type Tier int

const (
	TierBad Tier = iota
	TierAcceptable
	TierGood
	TierExcellent
	TierUnknown
)

func (t Tier) String() string {
	switch t {
	case TierBad:
		return "bad"
	case TierAcceptable:
		return "acceptable"
	case TierGood:
		return "good"
	case TierExcellent:
		return "excellent"
	default:
		return "unknown"
	}
}

// ParseTier — обратное к String(); неизвестная строка → TierUnknown.
func ParseTier(s string) Tier {
	switch s {
	case "bad":
		return TierBad
	case "acceptable":
		return TierAcceptable
	case "good":
		return TierGood
	case "excellent":
		return TierExcellent
	default:
		return TierUnknown
	}
}

// rank для сравнения версий: чем больше — тем лучше.
func (t Tier) rank() int {
	switch t {
	case TierExcellent:
		return 4
	case TierGood:
		return 3
	case TierAcceptable:
		return 2
	case TierUnknown:
		return 1
	default:
		return 0
	}
}

// Нижние границы tier'а в kbps по mime: {bad, acceptable, good}.
// mp3: порог 192 (Alex TG 24.09.2026 — сначала попросил 224, следом сам же
// «давай всё-таки 192 тогда сделаем и всё больше не меняем» — 192 ФИНАЛЬНОЕ
// решение, не трогать без нового явного «да» от Alex). Ниже 192 не качаем;
// acceptable-диапазон для mp3 фактически пуст (bad==acceptable==192).
var qualityRules = map[string][3]int{
	"audio/mpeg": {192, 192, 320}, // mp3
	"audio/mp4":  {96, 128, 256},  // AAC в .m4a
	"audio/aac":  {96, 128, 256},
	"audio/opus": {80, 128, 192},
	"audio/ogg":  {80, 128, 192},
	"audio/webm": {80, 128, 192},
}

var losslessMimes = map[string]bool{"audio/flac": true, "audio/wav": true}

var extToMime = map[string]string{
	"mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac",
	"opus": "audio/opus", "ogg": "audio/ogg", "flac": "audio/flac",
	"wav": "audio/wav", "webm": "audio/webm",
}

const unknownMimeBadBelow = 96

// MimeFromExt — mime по расширению пути. По умолчанию audio/mpeg.
func MimeFromExt(path string) string {
	ext := strings.TrimPrefix(strings.ToLower(filepath.Ext(path)), ".")
	if m, ok := extToMime[ext]; ok {
		return m
	}
	return "audio/mpeg"
}

// ClassifyAudio — tier, играбельность и человекочитаемая причина.
// bitrate <= 0 означает «неизвестен» → tier unknown, играбельно.
func ClassifyAudio(mime string, bitrateKbps int) (tier Tier, playable bool, reason string) {
	if losslessMimes[mime] {
		return TierExcellent, true, mime + " lossless"
	}
	if bitrateKbps <= 0 {
		return TierUnknown, true, "битрейт неизвестен"
	}
	r, known := qualityRules[mime]
	if !known {
		if bitrateKbps < unknownMimeBadBelow {
			return TierBad, false, fmt.Sprintf("незнакомый формат %q %dk < %d", mime, bitrateKbps, unknownMimeBadBelow)
		}
		return TierAcceptable, true, fmt.Sprintf("незнакомый формат %q %dk (осторожно)", mime, bitrateKbps)
	}
	switch {
	case bitrateKbps < r[0]:
		return TierBad, false, fmt.Sprintf("%s %dk < порога %d", mime, bitrateKbps, r[0])
	case bitrateKbps < r[1]:
		return TierAcceptable, true, fmt.Sprintf("%s %dk — приемлемо", mime, bitrateKbps)
	case bitrateKbps < r[2]:
		return TierGood, true, fmt.Sprintf("%s %dk — хорошо", mime, bitrateKbps)
	default:
		return TierExcellent, true, fmt.Sprintf("%s %dk — отлично", mime, bitrateKbps)
	}
}

// CompareAudio > 0 если a лучше b, < 0 если b лучше, 0 если равны.
// Lossless всегда выше сжатого (битрейт у него не показатель); дальше — tier,
// при равном tier — битрейт (неизвестный считаем худшим).
func CompareAudio(aMime string, aBitrate int, bMime string, bBitrate int) int {
	aLossless, bLossless := losslessMimes[aMime], losslessMimes[bMime]
	if aLossless != bLossless {
		if aLossless {
			return 1
		}
		return -1
	}
	if aLossless && bLossless {
		return 0
	}
	at, _, _ := ClassifyAudio(aMime, aBitrate)
	bt, _, _ := ClassifyAudio(bMime, bBitrate)
	if at.rank() != bt.rank() {
		return at.rank() - bt.rank()
	}
	abr, bbr := aBitrate, bBitrate
	if abr <= 0 {
		abr = -1
	}
	if bbr <= 0 {
		bbr = -1
	}
	return abr - bbr
}

// ShouldReplace — заменять ли existing на candidate (candidate строго лучше).
func ShouldReplace(existingMime string, existingBitrate int, candidateMime string, candidateBitrate int) bool {
	return CompareAudio(candidateMime, candidateBitrate, existingMime, existingBitrate) > 0
}
