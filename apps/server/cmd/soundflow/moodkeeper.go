package main

import (
	"context"
	_ "embed"
	"encoding/binary"
	"fmt"
	"log"
	"math"
	"sort"
	"time"

	"soundflow/server/internal/localdb"
)

// Программа сама знает настроение и жанр каждой песни (27.09.2026, Alex «делай»: «настроение
// поделено по 3900 песен — мы не умеем считывать настроение?»; «жанров очень много»).
//
// Настроение: нейросеть отпечатков (PANNs CNN14) обучена на AudioSet, где есть классы «Happy / Funny /
// Sad / Tender / Exciting / Angry / Scary music». Её последний слой (fc_audioset) в нашу модель не вошёл —
// веса этих 7 классов вынуты из исходного файла Cnn14_mAP=0.431.pth в mood_weights.bin. Отпечаток песни —
// ровно вход этого слоя, поэтому настроение считается по УЖЕ готовым отпечаткам, файлы не слушаем заново.
// 7 классов сведены в 5; чтобы большинство не утекало в «энергичное», каждое сравнивается со своим средним
// по коллекции (z-оценка), песня получает самое выраженное.
//
// Жанр: у ~28% песен Яндекс жанра не знает (метка «-»). Им жанр угадывается по 15 самым похожим по
// звуку песням с известным жанром: побеждает самая частая группа (Поп, Рок, Рэп…), записывается самый
// частый жанр внутри неё (genre_guess). Настоящий жанр Яндекса всегда главнее.
// Музыкальные файлы не трогает — только две колонки в базе.

//go:embed mood_weights.bin
var moodWeightsRaw []byte

const (
	moodFirstDelay = 6 * time.Minute
	moodEvery      = 6 * time.Hour
	moodKickSettle = 40 * time.Second
	genreNeighbors = 15
)

// Порядок 6 настроений и из каких классов AudioSet они собраны (номера строк в mood_weights.bin).
// 27.09.2026 (Alex «для симметрии 6 настроение», выбрал «Танцевальное»): строка 7 — класс AudioSet
// 274 «Dance music», дописан в mood_weights.bin после 276–282.
var moodNames = []string{"happy", "sad", "tender", "energetic", "aggressive", "dance"}
var moodFrom = [][]int{{0, 1}, {2, 6}, {3}, {4}, {5}, {7}} // happy+funny, sad+scary, tender, exciting, angry, dance

type moodKeeper struct {
	s      *Service
	kick   chan struct{}
	cancel context.CancelFunc
}

func newMoodKeeper(s *Service) *moodKeeper { return &moodKeeper{s: s, kick: make(chan struct{}, 1)} }

func (k *moodKeeper) Start() {
	ctx, cancel := context.WithCancel(context.Background())
	k.cancel = cancel
	go k.run(ctx)
}

func (k *moodKeeper) Stop() {
	if k != nil && k.cancel != nil {
		k.cancel()
	}
}

func (k *moodKeeper) Kick() {
	if k == nil {
		return
	}
	select {
	case k.kick <- struct{}{}:
	default:
	}
}

func (k *moodKeeper) run(ctx context.Context) {
	first := time.After(moodFirstDelay)
	tick := time.NewTicker(moodEvery)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-first:
		case <-tick.C:
		case <-k.kick:
			if !sleepCtx(ctx, moodKickSettle) {
				return
			}
		}
		if err := k.pass(ctx); err != nil && ctx.Err() == nil {
			log.Printf("хранитель настроения: %v", err)
		}
	}
}

func moodWeights() (w [][]float32, b []float32) {
	const dim, n = 2048, 8
	f := func(i int) float32 { return math.Float32frombits(binary.LittleEndian.Uint32(moodWeightsRaw[i*4:])) }
	w = make([][]float32, n)
	for r := 0; r < n; r++ {
		w[r] = make([]float32, dim)
		for c := 0; c < dim; c++ {
			w[r][c] = f(r*dim + c)
		}
	}
	b = make([]float32, n)
	for r := 0; r < n; r++ {
		b[r] = f(n*dim + r)
	}
	return
}

func logAddExp(a, b float64) float64 {
	m := math.Max(a, b)
	return m + math.Log(math.Exp(a-m)+math.Exp(b-m))
}

// moodScores — 6 логитов настроения для отпечатка.
func moodScores(v []float32, w [][]float32, b []float32) []float64 {
	raw := make([]float64, len(w))
	for r := range w {
		s := float64(b[r])
		for i, x := range v {
			if i >= len(w[r]) {
				break
			}
			s += float64(x) * float64(w[r][i])
		}
		raw[r] = s
	}
	out := make([]float64, len(moodFrom))
	for i, idx := range moodFrom {
		out[i] = raw[idx[0]]
		for _, j := range idx[1:] {
			out[i] = logAddExp(out[i], raw[j])
		}
	}
	return out
}

func (k *moodKeeper) pass(ctx context.Context) error {
	s := k.s
	if s.db == nil {
		return nil
	}
	rows, err := s.db.VectorsForMood()
	if err != nil {
		return err
	}
	if len(rows) == 0 {
		return nil
	}
	// --- настроение: z-оценка по коллекции ---
	w, b := moodWeights()
	scores := make([][]float64, len(rows))
	mean := make([]float64, len(moodNames))
	for i, r := range rows {
		scores[i] = moodScores(r.Vec, w, b)
		for j, x := range scores[i] {
			mean[j] += x
		}
	}
	for j := range mean {
		mean[j] /= float64(len(rows))
	}
	std := make([]float64, len(moodNames))
	for _, sc := range scores {
		for j, x := range sc {
			std[j] += (x - mean[j]) * (x - mean[j])
		}
	}
	for j := range std {
		std[j] = math.Sqrt(std[j]/float64(len(rows))) + 1e-9
	}
	current, _ := s.db.TrackMoods()
	moods := map[string]string{}
	for i, r := range rows {
		best, bi := math.Inf(-1), 0
		for j, x := range scores[i] {
			if z := (x - mean[j]) / std[j]; z > best {
				best, bi = z, j
			}
		}
		if current[r.ID] != moodNames[bi] {
			moods[r.ID] = moodNames[bi]
		}
	}
	if err := s.db.SetMoods(moods); err != nil {
		return err
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	// --- угаданный жанр для «Яндекс не знает» ---
	var known []localdb.VecRow
	var todo []localdb.VecRow
	for _, r := range rows {
		switch {
		case r.Genre != "" && r.Genre != localdb.GenreUnknown:
			known = append(known, r)
		case r.Genre == localdb.GenreUnknown && r.Guess == "":
			todo = append(todo, r)
		}
	}
	norm := func(v []float32) float64 {
		var s float64
		for _, x := range v {
			s += float64(x) * float64(x)
		}
		return math.Sqrt(s) + 1e-12
	}
	kn := make([]float64, len(known))
	for i, r := range known {
		kn[i] = norm(r.Vec)
	}
	guesses := map[string]string{}
	type nb struct {
		sim float64
		g   string
	}
	for ti, t := range todo {
		if ti%200 == 0 && ctx.Err() != nil {
			return ctx.Err()
		}
		tn := norm(t.Vec)
		best := make([]nb, 0, genreNeighbors+1)
		for i, r := range known {
			var dot float64
			for j, x := range t.Vec {
				if j >= len(r.Vec) {
					break
				}
				dot += float64(x) * float64(r.Vec[j])
			}
			sim := dot / (tn * kn[i])
			if len(best) < genreNeighbors || sim > best[len(best)-1].sim {
				best = append(best, nb{sim, r.Genre})
				sort.Slice(best, func(a, b int) bool { return best[a].sim > best[b].sim })
				if len(best) > genreNeighbors {
					best = best[:genreNeighbors]
				}
			}
		}
		groups := map[string]int{}
		codes := map[string]map[string]int{}
		for _, n := range best {
			g := genreGroup(n.g)
			groups[g]++
			if codes[g] == nil {
				codes[g] = map[string]int{}
			}
			codes[g][n.g]++
		}
		topG, topN := "", 0
		for g, n := range groups {
			if n > topN || (n == topN && g < topG) {
				topG, topN = g, n
			}
		}
		topC, topCN := "", 0
		for c, n := range codes[topG] {
			if n > topCN || (n == topCN && c < topC) {
				topC, topCN = c, n
			}
		}
		if topC != "" {
			guesses[t.ID] = topC
		}
	}
	if err := s.db.SetGenreGuesses(guesses); err != nil {
		return err
	}
	if len(moods) > 0 || len(guesses) > 0 {
		msg := fmt.Sprintf("Настроение: обновлено у %d песен; жанр угадан по звуку у %d", len(moods), len(guesses))
		log.Print("хранитель " + msg)
		_ = s.db.AddServerLog("info", "", "", msg, 0)
	}
	return nil
}

// genreGroup — большая группа жанра (тот же список, что на телефоне, apps/mobile/lib/core/genres.dart).
func genreGroup(code string) string {
	if g, ok := genreGroups[code]; ok {
		return g
	}
	return "other"
}

var genreGroups = func() map[string]string {
	m := map[string]string{}
	add := func(g string, codes ...string) {
		for _, c := range codes {
			m[c] = g
		}
	}
	add("pop", "pop", "ruspop", "kpop", "turkishpop", "disco", "vocal", "hyperpopgenre", "levantpop", "qazaqpop", "arabicpop")
	add("estrada", "rusestrada", "estrada", "shanson", "bard", "foreignbard", "kazestrada")
	add("dance", "dance", "electronics", "house", "techno", "trance", "edmgenre", "dnb", "dubstep", "breakbeatgenre", "idmgenre", "ukgaragegenre", "experimental")
	add("rap", "rap", "rusrap", "foreignrap", "phonkgenre")
	// 27.09.2026 (Alex «12 жанр»): альтернатива и инди — отдельной группой, не внутри рока.
	add("rock", "rock", "rusrock", "hardrock", "punk", "allrock", "prog", "folkrock", "ukrrock", "rnr", "ska")
	add("alt", "alternative", "indie", "local-indie", "postpunk", "newwave", "modern")
	add("metal", "numetal", "classicmetal", "metal", "alternativemetal", "metalcoregenre", "thrashmetal", "industrial", "posthardcore", "epicmetal", "progmetal", "hardcore")
	add("rnb", "rnb", "soul", "funk", "reggae", "reggaeton", "dub")
	add("calm", "lounge", "relax", "ambientgenre", "newage", "triphopgenre", "lullaby", "classical", "meditation")
	add("jazz", "jazz", "vocaljazz", "conjazz", "bestofjazz", "tradjazz", "blues", "smoothjazz", "bebopgenre")
	add("folk", "folk", "country", "amerfolk", "folkgenre", "latinfolk", "african", "caucasian")
	add("soundtrack", "soundtrack", "films", "videogame", "animated", "children", "sport", "musical")
	return m
}()
