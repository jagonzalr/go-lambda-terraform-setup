package handler

// Create -
func Create() Handler {
	config := NewConfigFromEnv()

	// Initialize some code like the Kinesis Client
	// sess := session.Must(session.NewSession(aws.NewConfig()))
	// kinesisClient := kinesis.New(sess)

	return NewLambdaHandler(config.randomName)
}
