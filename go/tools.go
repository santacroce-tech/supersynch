//go:build tools

// Keeps gomobile's bind package in go.mod (needed by `gomobile bind`).
package tools

import _ "golang.org/x/mobile/bind"
