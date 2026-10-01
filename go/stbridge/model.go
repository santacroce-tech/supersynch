package stbridge

import (
	"errors"
	"reflect"
	"unsafe"

	"github.com/syncthing/syncthing/lib/model"
	"github.com/syncthing/syncthing/lib/syncthing"
)

// modelOf returns the running model behind app.Internals.
//
// lib/syncthing exposes only a subset of the model through Internals and
// keeps the model itself in an unexported field. Several things the web GUI
// shows (connection statistics, persisted pending devices, folder statistics,
// versions, the folder summary service) need the full model.Model, so we read
// that field via reflection. This is pinned to the vendored Syncthing commit
// and verified by TestModelAccess; re-check it when upgrading Syncthing.
func modelOf(app *syncthing.App) (model.Model, error) {
	if app == nil || app.Internals == nil {
		return nil, errors.New("syncthing is not running")
	}
	field := reflect.ValueOf(app.Internals).Elem().FieldByName("model")
	if !field.IsValid() {
		return nil, errors.New("embedded Syncthing internals changed: no model field")
	}
	// The field is unexported, so build an addressable alias to read it.
	value := reflect.NewAt(field.Type(), unsafe.Pointer(field.UnsafeAddr())).Elem().Interface()
	m, ok := value.(model.Model)
	if !ok || m == nil {
		return nil, errors.New("embedded Syncthing internals changed: model has unexpected type")
	}
	return m, nil
}
