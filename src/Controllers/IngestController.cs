// IngestController.cs

using Microsoft.AspNetCore.Mvc;
using Azure.Storage.Files.DataLake; // Main ADLS client
using Azure.Identity; // For DefaultAzureCredential
using System.Text; // For encoding
using System.IO; // For StreamReader/MemoryStream
using System; // For DateTime/Guid
using Microsoft.Extensions.Logging; // For ILogger
using Microsoft.Extensions.Configuration; // For IConfiguration
using System.Linq; // For FirstOrDefault() on header value
using System.Threading.Tasks; // For Task/async/await

// Ensure the namespace matches your project name
namespace iotdn_api1.Controllers;

[ApiController]
public class IngestController : ControllerBase
{
    private readonly IConfiguration _configuration;
    private readonly ILogger<IngestController> _logger;
    private readonly DataLakeServiceClient _dataLakeServiceClient;

    // Expected header name for the simple API key
    private const string ApiKeyHeaderName = "X-API-Key";

    public IngestController(IConfiguration configuration, ILogger<IngestController> logger)
    {
        _configuration = configuration ?? throw new ArgumentNullException(nameof(configuration));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));

        // --- Connect to ADLS using Managed Identity (via DefaultAzureCredential) ---
        string accountName = _configuration["STORAGE_ACCOUNT_NAME"]
            ?? throw new InvalidOperationException("STORAGE_ACCOUNT_NAME is not configured."); // Use InvalidOperationException for config errors

        // Construct the ADLS URI (using dfs endpoint)
        Uri dataLakeUri = new($"https://{accountName}.dfs.core.windows.net");

        // DefaultAzureCredential will automatically use the App Service's Managed Identity when deployed.
        // IMPORTANT: Ensure the App Service Managed Identity has 'Storage Blob Data Contributor' role on the Storage Account.
        try
        {
             _dataLakeServiceClient = new DataLakeServiceClient(dataLakeUri, new DefaultAzureCredential());
        }
        catch (Exception ex)
        {
             _logger.LogError(ex, "Failed to create DataLakeServiceClient. Check configuration and Azure credentials.");
             // Rethrow or handle appropriately depending on requirements
             // For startup, rethrowing might be okay to prevent the app starting without ADLS access
             throw;
        }
        // --- End ADLS Connection ---
    }

    [HttpPost] // Handles POST requests
    [Route("/api/ingest")] // Route for the endpoint
    public async Task<IActionResult> Post() // Use IActionResult for flexible responses
    {
        // --- 1. Check API Key ---
        if (!Request.Headers.TryGetValue(ApiKeyHeaderName, out var receivedApiKeyHeaderValue) || !receivedApiKeyHeaderValue.Any())
        {
            _logger.LogWarning("API Key header '{HeaderName}' missing or empty.", ApiKeyHeaderName);
            return Unauthorized($"API Key header '{ApiKeyHeaderName}' missing or empty."); // 401 Unauthorized
        }

        string receivedApiKey = receivedApiKeyHeaderValue.First() ?? ""; // Get first value
        string? expectedApiKey = _configuration["APP_API_KEY"];

        // Basic check - consider more secure comparison for production
        if (string.IsNullOrEmpty(expectedApiKey) || !expectedApiKey.Equals(receivedApiKey))
        {
            _logger.LogWarning("Invalid API Key received.");
            // Don't log the received key unless necessary for debugging internal systems
            return Unauthorized("Invalid API Key."); // 401 Unauthorized
        }
        // --- End API Key Check ---

        // --- 2. Read Request Body (JSON Payload) ---
        string requestBody;
        try
        {
            using (var reader = new StreamReader(Request.Body, Encoding.UTF8))
            {
                // Read the body asynchronously
                requestBody = await reader.ReadToEndAsync();
            }

            if (string.IsNullOrWhiteSpace(requestBody))
            {
                _logger.LogWarning("Received empty request body.");
                return BadRequest("Request body cannot be empty."); // 400 Bad Request
            }
            // TODO: Optionally, validate if requestBody is valid JSON here (e.g., using System.Text.Json)
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error reading request body.");
            return BadRequest("Error reading request body."); // 400 Bad Request
        }
        // --- End Read Request Body ---


        // --- 3. Write to ADLS ---
        try
        {
            string containerName = _configuration["STORAGE_CONTAINER_NAME"]
                ?? throw new InvalidOperationException("STORAGE_CONTAINER_NAME is not configured.");

            // Get a client for the specific container (filesystem in ADLS terms)
            DataLakeFileSystemClient fileSystemClient = _dataLakeServiceClient.GetFileSystemClient(containerName);

            // Define a path and filename within the container
            DateTime now = DateTime.UtcNow;
            string filePath = $"{now:yyyy}/{now:MM}/{now:dd}/{now:HH}/{Guid.NewGuid()}.json";

            DataLakeFileClient fileClient = fileSystemClient.GetFileClient(filePath);

            // Convert the JSON string body to a byte array using UTF8 encoding
            byte[] dataBytes = Encoding.UTF8.GetBytes(requestBody);

            // Upload the data as a stream
            using (var stream = new MemoryStream(dataBytes))
            {
                // Creates directories if they don't exist.
                // Consider setting CancellationToken if needed for long uploads
                await fileClient.UploadAsync(content: stream, overwrite: true); // 'true' overwrites (unlikely with GUIDs)
                _logger.LogInformation("Successfully uploaded data to ADLS path: {FilePath} in container {ContainerName}", filePath, containerName);
            }

            // 202 Accepted is suitable for async processing/ingestion pipelines.
            // Use Ok() (200) if processing is considered complete synchronously.
            return Accepted(); // HTTP 202

        }
        // Catch specific Azure exceptions if needed for more granular error handling
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error writing data to ADLS.");
            // Return a generic 500 error to the client
            return StatusCode(StatusCodes.Status500InternalServerError, "An internal error occurred while processing the request.");
        }
        // --- End Write to ADLS ---
    }
}