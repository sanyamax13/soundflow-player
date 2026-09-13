package localdb

import (
	"fmt"
	"os"
	"testing"
)

// TestTasteHistogramReport — НЕ проверяет поведение, печатает распределение
// sim/aff на реальной базе перед тем, как менять формулу радио (Task 5).
// Пропускается, если SOUNDFLOW_LAB_DB не задан (обычный `go test ./...` его
// не запускает и не падает).
func TestTasteHistogramReport(t *testing.T) {
	path := os.Getenv("SOUNDFLOW_LAB_DB")
	if path == "" {
		t.Skip("SOUNDFLOW_LAB_DB не задан — пропуск (это разовая диагностика, не CI-тест)")
	}
	d, err := Open(path + "?mode=ro")
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()

	if _, _, err := d.RecomputeTasteClusters("long_term", nil); err != nil {
		t.Fatal(err)
	}
	cents, err := d.tasteCentroidsLayer("long_term")
	if err != nil {
		t.Fatal(err)
	}
	if len(cents) == 0 {
		t.Skip("нет центров вкуса на этой базе — гистограмма невозможна")
	}

	rows, err := d.sql.Query(`SELECT feature_vector FROM tracks WHERE feature_vector IS NOT NULL LIMIT 2000`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	buckets := make([]int, 10) // 0.0-0.1, 0.1-0.2, ..., 0.9-1.0
	n := 0
	for rows.Next() {
		var blob []byte
		if err := rows.Scan(&blob); err != nil {
			t.Fatal(err)
		}
		v := blobToVec(blob)
		if len(v) == 0 {
			continue
		}
		a := tasteAffinity(cents, v)
		bi := int(a * 10)
		if bi > 9 {
			bi = 9
		}
		buckets[bi]++
		n++
	}
	fmt.Printf("\n=== aff-гистограмма по %d трекам (long_term, %d центров) ===\n", n, len(cents))
	for i, c := range buckets {
		fmt.Printf("  %.1f-%.1f: %d (%.1f%%)\n", float64(i)/10, float64(i+1)/10, c, 100*float64(c)/float64(n))
	}
}
