package main

import (
    "net/http"
    "log"
)

func main() {
    err := http.ListenAndServe(":8082", http.FileServer(http.Dir("../build/images/amd64-usr/latest/")))
    if err != nil {
        log.Printf("Error running web server for static assets: %v", err)
    }
}
