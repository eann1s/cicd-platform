package main

import (
	"bytes"
	"io"
	"os"
	"testing"
)


func TestMainOutput(t *testing.T) {
	old := os.Stdout

	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}

	os.Stdout = w
	defer func () { os.Stdout = old }()

	main()
	
	err = w.Close()
	if err != nil {
		t.Fatal(err)
	}

	var buf bytes.Buffer
	_, err = io.Copy(&buf, r)
	if err != nil {
		t.Fatal(err)
	}

	expected := "Hello World!\n"
	if buf.String() != expected {
		t.Errorf("Expected '%s', got '%s'", expected, buf.String())
	}
}
