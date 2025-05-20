// src/ingest_api/Program.cs

using Azure.Identity;
using Azure.Storage.Files.DataLake;

var builder = WebApplication.CreateBuilder(args);

// 1) Register the ADLS Gen2 client for DI
builder.Services.AddSingleton(sp =>
{
  var cfg = sp.GetRequiredService<IConfiguration>();
  var acct = cfg["STORAGE_ACCOUNT_NAME"]
      ?? throw new InvalidOperationException("STORAGE_ACCOUNT_NAME is not configured.");
  var uri = new Uri($"https://{acct}.dfs.core.windows.net");
  return new DataLakeServiceClient(uri, new DefaultAzureCredential());
});

// 2) Add MVC controllers
builder.Services.AddControllers();

var app = builder.Build();

// 3) Map controller routes
app.MapControllers();

app.Run();
