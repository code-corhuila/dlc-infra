// launcher loads local runtime environment values without invoking a shell.
package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"
	"syscall"
)

func main() {
	if len(os.Args) < 2 || os.Getenv("DLC_LAUNCH_ENV") == "" {
		fail("missing environment file or executable")
	}
	f, err := os.Open(os.Getenv("DLC_LAUNCH_ENV"))
	if err != nil { fail("cannot open runtime environment") }
	defer f.Close()
	s := bufio.NewScanner(f)
	s.Buffer(make([]byte, 4096), 1024*1024)
	for s.Scan() {
		line := s.Text()
		if line == "" || strings.HasPrefix(line, "#") { continue }
		key, value, found := strings.Cut(line, "=")
		if !found || key == "" || strings.ContainsAny(key, " \t\r\n") { fail("invalid runtime environment") }
		if (key == "IAM_TRUSTED_GATEWAY_IP" || key == "IAM_AUTH_ALLOWED_ORIGIN") && os.Getenv(key) != "" { continue }
		if os.Setenv(key, value) != nil { fail("invalid runtime environment") }
	}
	if s.Err() != nil { fail("cannot read runtime environment") }
	path := os.Args[1]
	if err := syscall.Exec(path, os.Args[1:], os.Environ()); err != nil { fail("cannot start service") }
}

func fail(message string) { fmt.Fprintln(os.Stderr, message); os.Exit(1) }
