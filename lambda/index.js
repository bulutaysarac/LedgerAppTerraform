const AWS = require('aws-sdk');
const axios = require('axios');

exports.handler = async (event) => {
    console.log("Received event:", JSON.stringify(event, null, 2));

    try {
        // Process each SQS message
        for (const record of event.Records) {
            const messageBody = JSON.parse(record.body);
            console.log("Processing message:", messageBody);

            // Call the Face API
            const faceApiResponse = await axios.post('https://faceapi.example.com/analyze', messageBody);
            console.log("Face API response:", faceApiResponse.data);
        }

        return {
            statusCode: 200,
            body: JSON.stringify({ message: "Processing completed." }),
        };
    } catch (error) {
        console.error("Error processing messages:", error);
        throw error;
    }
};
