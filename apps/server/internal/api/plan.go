package api

import (
	"encoding/json"
	"net/http"

	"soundflow/server/internal/db"
)

// «Ручная синхронизация телефона» (Alex TG 19000, 19002): выбор — что
// добавить/убрать — Alex делает в окне на компе (кнопка «Синхронизировать» →
// список с галочками → «Далее»), окно сохраняет план в базу. Телефон только
// исполняет: тут он его забирает и, выполнив, отчитывается.

// GET /v1/device/plan?device=X — активный план устройства.
//
//	{"add":[<карточка трека>,…],"remove":["id",…],"created_at":"…"}
//
// add — полные карточки (телефон по ним качает файл и обложку), remove —
// только id (телефон стирает у себя). Плана нет или он пустой → 204,
// телефон ничего не делает.
func (s *Server) devicePlan(w http.ResponseWriter, r *http.Request) {
	dev := r.URL.Query().Get("device")
	if dev == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "нужен параметр device"})
		return
	}
	if s.DB.Ping(r.Context()) != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "база недоступна"})
		return
	}
	add, remove, at, ok, err := s.DB.DevicePlan(r.Context(), dev)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	if !ok || (len(add) == 0 && len(remove) == 0) {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if add == nil {
		add = []db.CatalogTrack{}
	}
	if remove == nil {
		remove = []string{}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"add":        add,
		"remove":     remove,
		"created_at": at,
	})
}

type planAckReq struct {
	Device string `json:"device"`
}

// POST /v1/device/plan/ack  {"device":"X"} — телефон выполнил план (скачал
// add, стёр remove). Сервер удаляет план — повторно телефон его не подхватит.
// Не отчитался (сеть моргнула) — план остаётся, подхватится в следующий
// заход; повторная закачка уже скачанного на телефоне пропускается.
func (s *Server) devicePlanAck(w http.ResponseWriter, r *http.Request) {
	var req planAckReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Device == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "нужен device"})
		return
	}
	if s.DB.Ping(r.Context()) != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "база недоступна"})
		return
	}
	if err := s.DB.ClearDevicePlan(r.Context(), req.Device); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"cleared": true})
}
