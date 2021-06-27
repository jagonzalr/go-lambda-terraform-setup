package handler

import (
	"os"
)

type config struct {
	randomEnv string
}

// NewConfigFromEnv -
func NewConfigFromEnv() *config {

	return &config{
		randomEnv: os.Getenv("RANDOM_ENV"),
	}
}
