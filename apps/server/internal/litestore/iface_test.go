package litestore

import (
	"testing"

	"soundflow/server/internal/acquire"
	"soundflow/server/internal/api"
	"soundflow/server/internal/importer"
)

// litestore.Store обязан удовлетворять всем трём интерфейсам-разъёмам —
// иначе «полностью новый сервер» не соберётся.
func TestStoreSatisfiesInterfaces(t *testing.T) {
	var _ api.Store = (*Store)(nil)
	var _ acquire.Store = (*Store)(nil)
	var _ importer.Store = (*Store)(nil)
}
