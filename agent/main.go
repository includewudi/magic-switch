package main

// bt-agent: MagicSwitch 的机器侧代理。
// 暴露 blueutil 的连接/断开/状态查询为局域网 HTTP 接口，供 MacBook 上的
// MagicSwitch.app 调用。仅依赖 blueutil 二进制，配置为 JSON 文件。

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type Config struct {
	Token   string   `json:"token"`   // X-Token 鉴权
	Listen  string   `json:"listen"`  // 监听地址
	Devices []string `json:"devices"` // 蓝牙设备 MAC，约定 [键盘, 鼠标]
}

var (
	cfg      Config
	blueutil string
)

func findBlueutil() string {
	for _, p := range []string{
		"/opt/homebrew/bin/blueutil",
		"/usr/local/bin/blueutil",
	} {
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			return p
		}
	}
	if p, err := exec.LookPath("blueutil"); err == nil {
		return p
	}
	return ""
}

func runBlueutil(args ...string) (string, error) {
	cmd := exec.Command(blueutil, args...)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	err := cmd.Run()
	return strings.TrimSpace(out.String()), err
}

func isConnected(addr string) bool {
	out, err := runBlueutil("--is-connected", addr)
	return err == nil && strings.Contains(out, "1")
}

// deviceKind: 按约定顺序，第 0 个是键盘，第 1 个是鼠标。
func deviceKind(i int) string {
	if i == 0 {
		return "keyboard"
	}
	return "mouse"
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Token") != cfg.Token {
			writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "bad token"})
			return
		}
		next.ServeHTTP(w, r)
	})
}

func lanOnly(r *http.Request) bool {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return false
	}
	ip := net.ParseIP(host)
	return ip != nil && (ip.IsLoopback() || ip.IsPrivate())
}

type devStatus struct {
	Addr      string `json:"addr"`
	Kind      string `json:"kind"`
	Connected bool   `json:"connected"`
}

func handleStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "GET only"})
		return
	}
	var mu sync.Mutex
	devs := make([]devStatus, len(cfg.Devices))
	var wg sync.WaitGroup
	for i, addr := range cfg.Devices {
		wg.Add(1)
		go func(i int, addr string) {
			defer wg.Done()
			s := devStatus{Addr: addr, Kind: deviceKind(i), Connected: isConnected(addr)}
			mu.Lock()
			devs[i] = s
			mu.Unlock()
		}(i, addr)
	}
	wg.Wait()
	any := false
	for _, d := range devs {
		if d.Connected {
			any = true
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": devs, "holding": any})
}

// connectOne 连接单设备，带重试。
func connectOne(addr string, attempts int) bool {
	for i := 0; i < attempts; i++ {
		out, err := runBlueutil("--connect", addr)
		if err == nil || isConnected(addr) {
			return true
		}
		log.Printf("connect %s attempt %d failed: %v %s", addr, i+1, err, out)
		time.Sleep(700 * time.Millisecond)
	}
	return isConnected(addr)
}

func handleConnect(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "POST only"})
		return
	}
	type result struct {
		Addr string `json:"addr"`
		Kind string `json:"kind"`
		OK   bool   `json:"ok"`
	}
	results := make([]result, len(cfg.Devices))
	var wg sync.WaitGroup
	for i, addr := range cfg.Devices {
		wg.Add(1)
		go func(i int, addr string) {
			defer wg.Done()
			results[i] = result{Addr: addr, Kind: deviceKind(i), OK: connectOne(addr, 3)}
		}(i, addr)
	}
	wg.Wait()
	all := true
	for _, res := range results {
		if !res.OK {
			all = false
		}
	}
	code := http.StatusOK
	if !all {
		code = http.StatusPartialContent // 200 全成，206 部分失败
	}
	writeJSON(w, code, map[string]any{"results": results, "all": all})
}

func handleDisconnect(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "POST only"})
		return
	}
	type result struct {
		Addr string `json:"addr"`
		Kind string `json:"kind"`
		OK   bool   `json:"ok"`
	}
	results := make([]result, len(cfg.Devices))
	for i, addr := range cfg.Devices {
		_, err := runBlueutil("--disconnect", addr)
		results[i] = result{Addr: addr, Kind: deviceKind(i), OK: err == nil}
	}
	writeJSON(w, http.StatusOK, map[string]any{"results": results})
}

func main() {
	configPath := flag.String("config", "", "配置文件路径")
	flag.Parse()
	if *configPath == "" {
		exe, _ := os.Executable()
		*configPath = filepath.Join(filepath.Dir(exe), "config.json")
	}
	raw, err := os.ReadFile(*configPath)
	if err != nil {
		log.Fatalf("read config %s: %v", *configPath, err)
	}
	if err := json.Unmarshal(raw, &cfg); err != nil {
		log.Fatalf("parse config: %v", err)
	}
	if cfg.Token == "" || len(cfg.Devices) == 0 {
		log.Fatalf("config 需要 token 和 devices")
	}
	if cfg.Listen == "" {
		cfg.Listen = "0.0.0.0:19821"
	}
	blueutil = findBlueutil()
	if blueutil == "" {
		log.Fatalf("找不到 blueutil，请先 brew install blueutil")
	}

	mux := http.NewServeMux()
	mux.Handle("/status", auth(http.HandlerFunc(handleStatus)))
	mux.Handle("/connect", auth(http.HandlerFunc(handleConnect)))
	mux.Handle("/disconnect", auth(http.HandlerFunc(handleDisconnect)))
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	})

	// 局域网限制
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !lanOnly(r) {
			writeJSON(w, http.StatusForbidden, map[string]any{"error": "lan only"})
			return
		}
		mux.ServeHTTP(w, r)
	})

	log.Printf("bt-agent listening on %s, devices=%v", cfg.Listen, cfg.Devices)
	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Fatal(srv.ListenAndServe())
}

var _ = fmt.Sprintf
