// src/ingest_api/Controllers/IngestController.cs

using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Azure.Storage.Files.DataLake;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace ingest_api.Controllers
{
  [ApiController]
  [Route("api/ingest")]
  public class IngestController : ControllerBase
  {
    private const string ApiKeyHeader = "X-API-Key";
    private readonly IConfiguration _config;
    private readonly ILogger<IngestController> _logger;
    private readonly DataLakeServiceClient _dlClient;

    public IngestController(
        IConfiguration config,
        ILogger<IngestController> logger,
        DataLakeServiceClient dlClient)
    {
      _config = config;
      _logger = logger;
      _dlClient = dlClient;
    }

    [HttpPost]
    public async Task<IActionResult> Post()
    {
      // 1) API key check
      if (!Request.Headers.TryGetValue(ApiKeyHeader, out var kv)
          || kv.FirstOrDefault() != _config["APP_API_KEY"])
      {
        _logger.LogWarning("Unauthorized ingest attempt");
        return Unauthorized();
      }

      // 2) Read the JSON body
      using var ms = new MemoryStream();
      await Request.Body.CopyToAsync(ms);
      if (ms.Length == 0)
      {
        _logger.LogWarning("Empty payload");
        return BadRequest("Empty payload");
      }
      ms.Position = 0;

      // 3) Upload to ADLS Gen2
      try
      {
        var container = _config["STORAGE_CONTAINER_NAME"]!;
        var fsClient = _dlClient.GetFileSystemClient(container);
        var now = DateTime.UtcNow;
        var path = $"{now:yyyy}/{now:MM}/{now:dd}/{now:HH}/{Guid.NewGuid()}.json";
        var fileClient = fsClient.GetFileClient(path);

        await fileClient.UploadAsync(ms, overwrite: true);
        _logger.LogInformation("Uploaded to {Path}", path);

        return Accepted();
      }
      catch (Exception ex)
      {
        _logger.LogError(ex, "Error writing to data lake");
        return StatusCode(500, "Internal error");
      }
    }
  }
}
