# Script chuyen doi HasColumnType tu SQL Server sang PostgreSQL
# Su dung: .\convert-to-postgres.ps1 -FilePath "path\to\your\context.cs"

param(
    [Parameter(Mandatory=$false)]
    [string]$FilePath = "Models\qcsysContextPoster.cs"
)

# Neu khong co FilePath, tim tat ca cac file *Context.cs
if (-not $FilePath) {
    $files = Get-ChildItem -Path . -Recurse -Filter "*Context.cs" | Where-Object { $_.Name -notlike "*PostgresContext.cs" }
    if ($files.Count -eq 0) {
        Write-Host "Khong tim thay file Context nao!" -ForegroundColor Red
        exit
    }
    Write-Host "Tim thay cac file:" -ForegroundColor Yellow
    $files | ForEach-Object { Write-Host "  - $($_.FullName)" }
    $FilePath = Read-Host "Nhap duong dan file can convert (hoac Enter de convert tat ca)"
    
    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        $FilePath = $files | ForEach-Object { $_.FullName }
    }
}

# Mapping SQL Server -> PostgreSQL
$mappings = @{
    # Kieu ngay gio
    'datetime'      = 'timestamp without time zone'
    'datetime2'     = 'timestamp'
    'smalldatetime' = 'timestamp'
    'datetimeoffset'= 'timestamp with time zone'
    'date'          = 'date'
    'time'          = 'time'
    
    # Kieu nhi phan
    'image'         = 'bytea'
    'binary'        = 'bytea'
    'varbinary'     = 'bytea'
    
    # Kieu chuoi
    'nvarchar'      = 'varchar'
    'nchar'         = 'char'
    'text'          = 'text'
    
    # Kieu so
    'money'         = 'money'
    'smallmoney'    = 'numeric(10,4)'
    'float'         = 'double precision'
    'real'          = 'real'
    
    # Khac
    'uniqueidentifier' = 'uuid'
    'xml'           = 'xml'
}

function Convert-ContextFile {
    param([string]$File)
    
    Write-Host "`nDang xu ly: $File" -ForegroundColor Cyan
    
    $content = Get-Content -Path $File -Raw -Encoding UTF8
    $originalContent = $content
    $changeCount = 0
    
    foreach ($key in $mappings.Keys) {
        $oldPattern = "HasColumnType\(`"$key`"\)"
        $newValue = $mappings[$key]
        
        if ($content -match $oldPattern) {
            $matches = [regex]::Matches($content, $oldPattern)
            $count = $matches.Count
            $content = $content -replace $oldPattern, "HasColumnType(`"$newValue`")"
            $changeCount += $count
            Write-Host "  Da thay: $key -> $newValue ($count lan)" -ForegroundColor Green
        }
    }
    
    # Xu ly truong hop co tham so nhu datetime2(7)
    $content = $content -replace 'HasColumnType\("datetime2\(\d+\)"\)', 'HasColumnType("timestamp")'
    
    if ($content -ne $originalContent) {
        Set-Content -Path $File -Value $content -Encoding UTF8 -NoNewline
        Write-Host "Hoan tat! Da thay doi $changeCount lan" -ForegroundColor Green
    } else {
        Write-Host "Khong co thay doi nao" -ForegroundColor Yellow
    }
}

# Xu ly file(s)
if ($FilePath -is [array]) {
    foreach ($file in $FilePath) {
        Convert-ContextFile -File $file
    }
} else {
    if (Test-Path $FilePath) {
        Convert-ContextFile -File $FilePath
    } else {
        Write-Host "File khong ton tai: $FilePath" -ForegroundColor Red
    }
}

Write-Host "`nHoan thanh!" -ForegroundColor Green









using ConsoleApp4.Models;
using EFCore.BulkExtensions;
using Microsoft.EntityFrameworkCore;

Console.WriteLine("=== Bat dau chuyen du lieu tu SQL Server sang PostgreSQL ===");

// Cau hinh batch size
// RAM 16GB: Nen dung 10,000-20,000 (entity don gian) hoac 5,000-10,000 (entity phuc tap/co blob)
const int BATCH_SIZE = 10000; // So luong record moi batch

try
{
    // Ket noi SQL Server
    using var sqlContext = new qcsysContextSQL();
    Console.WriteLine("Da ket noi SQL Server");

    // Ket noi PostgreSQL
    using var pgContext = new qcsysContextPoster();
    Console.WriteLine("Da ket noi PostgreSQL");

    // Tao database schema neu chua ton tai
    Console.WriteLine("\nDang tao database schema...");
    var created = await pgContext.Database.EnsureCreatedAsync();
    Console.WriteLine(created ? "Da tao database moi" : "Database da ton tai");
    
    // Kiem tra ket noi
    var canConnect = await pgContext.Database.CanConnectAsync();
    Console.WriteLine($"Kiem tra ket noi: {(canConnect ? "Thanh cong" : "That bai")}");

    // Xoa du lieu cu trong PostgreSQL (neu can)
    Console.WriteLine("\nBan co muon xoa du lieu cu trong PostgreSQL? (y/n)");
    var clearData = Console.ReadLine()?.ToLower() == "y";

    if (clearData)
    {
        try
        {
            await pgContext.Database.ExecuteSqlRawAsync("DELETE FROM \"Supplier\"");
            await pgContext.Database.ExecuteSqlRawAsync("DELETE FROM \"Product\"");
            await pgContext.Database.ExecuteSqlRawAsync("DELETE FROM \"Category\"");
            Console.WriteLine("Da xoa du lieu cu");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Khong the xoa du lieu cu (co the bang chua ton tai): {ex.Message}");
        }
    }

    // Lay tat ca DbSet tu context
    var sqlDbSets = sqlContext.GetType()
        .GetProperties()
        .Where(p => p.PropertyType.IsGenericType && 
                    p.PropertyType.GetGenericTypeDefinition() == typeof(DbSet<>))
        .ToList();

    Console.WriteLine($"\nTim thay {sqlDbSets.Count} bang de import");

    // Import tung bang
    foreach (var dbSetProperty in sqlDbSets)
    {
        var tableName = dbSetProperty.Name;
        Console.WriteLine($"\n--- Import {tableName} ---");

        try
        {
            var entityType = dbSetProperty.PropertyType.GetGenericArguments()[0];
            
            // Dem tong so record
            var sqlDbSet = dbSetProperty.GetValue(sqlContext);
            var countAsyncMethod = typeof(EntityFrameworkQueryableExtensions)
                .GetMethods()
                .First(m => m.Name == "CountAsync" && m.GetParameters().Length == 2)
                .MakeGenericMethod(entityType);
            
            var countTask = (Task<int>)countAsyncMethod.Invoke(null, new[] { sqlDbSet, CancellationToken.None })!;
            var totalRecords = await countTask;
            
            if (totalRecords == 0)
            {
                Console.WriteLine("Khong co du lieu");
                continue;
            }
            
            Console.WriteLine($"Tong so: {totalRecords:N0} records");
            Console.WriteLine($"Se import theo batch {BATCH_SIZE:N0} records/lan");
            
            // Import theo batch
            int imported = 0;
            int batchNumber = 0;
            
            while (imported < totalRecords)
            {
                batchNumber++;
                
                // Lay batch data tu SQL Server
                var skipMethod = typeof(Queryable)
                    .GetMethods()
                    .First(m => m.Name == "Skip" && m.GetParameters().Length == 2)
                    .MakeGenericMethod(entityType);
                    
                var takeMethod = typeof(Queryable)
                    .GetMethods()
                    .First(m => m.Name == "Take" && m.GetParameters().Length == 2)
                    .MakeGenericMethod(entityType);
                
                var asNoTrackingMethod = typeof(EntityFrameworkQueryableExtensions)
                    .GetMethod("AsNoTracking")!
                    .MakeGenericMethod(entityType);
                
                var query = asNoTrackingMethod.Invoke(null, new[] { sqlDbSet });
                query = skipMethod.Invoke(null, new[] { query, imported });
                query = takeMethod.Invoke(null, new[] { query, BATCH_SIZE });
                
                var toListAsyncMethod = typeof(EntityFrameworkQueryableExtensions)
                    .GetMethods()
                    .First(m => m.Name == "ToListAsync" && m.GetParameters().Length == 2)
                    .MakeGenericMethod(entityType);
                
                var dataTask = (Task)toListAsyncMethod.Invoke(null, new[] { query, CancellationToken.None })!;
                await dataTask;
                
                var batchData = dataTask.GetType().GetProperty("Result")!.GetValue(dataTask);
                int batchCount = ((System.Collections.IEnumerable)batchData!).Cast<object>().Count();
                
                if (batchCount == 0) break;
                
                // Bulk insert batch
                var bulkInsertAsyncMethod = typeof(EFCore.BulkExtensions.DbContextBulkExtensions)
                    .GetMethods()
                    .First(m => m.Name == "BulkInsertAsync" && 
                               m.GetParameters().Length == 6 &&
                               m.GetParameters()[1].ParameterType.IsGenericType)
                    .MakeGenericMethod(entityType);
                
                await (Task)bulkInsertAsyncMethod.Invoke(null, new[] { pgContext, batchData, null, null, null, CancellationToken.None })!;
                
                imported += batchCount;
                var percent = (imported * 100.0 / totalRecords);
                Console.Write($"\rBatch #{batchNumber}: {imported:N0}/{totalRecords:N0} ({percent:F1}%)");
            }
            
            Console.WriteLine($"\n✓ Hoan thanh {tableName}: {imported:N0} records");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"\nLoi khi import {tableName}: {ex.Message}");
            Console.WriteLine($"Chi tiet: {ex.InnerException?.Message}");
        }
    }

    Console.WriteLine("\n=== Hoan thanh! Tat ca du lieu da duoc chuyen sang PostgreSQL ===");
}
catch (Exception ex)
{
    Console.WriteLine($"\nLoi: {ex.Message}");
    Console.WriteLine($"Chi tiet: {ex.InnerException?.Message}");
    Console.WriteLine($"\nStack trace:\n{ex.StackTrace}");
}



<ItemGroup>
		<PackageReference Include="EFCore.BulkExtensions" Version="8.1.0" />
		<PackageReference Include="Microsoft.EntityFrameworkCore.SqlServer" Version="8.0.7" />
		<PackageReference Include="Microsoft.EntityFrameworkCore.Tools" Version="8.0.0">
			<IncludeAssets>runtime; build; native; contentfiles; analyzers; buildtransitive</IncludeAssets>
			<PrivateAssets>all</PrivateAssets>
		</PackageReference>
		<PackageReference Include="Microsoft.Extensions.Configuration" Version="10.0.0" />
		<PackageReference Include="Microsoft.Extensions.Configuration.Json" Version="10.0.0" />
		<PackageReference Include="Microsoft.Extensions.DependencyInjection" Version="10.0.0" />
		<PackageReference Include="Npgsql.EntityFrameworkCore.PostgreSQL" Version="8.0.4" />
	</ItemGroup>


 protected override void OnConfiguring(DbContextOptionsBuilder optionsBuilder)
#warning To protect potentially sensitive information in your connection string, you should move it out of source code. You can avoid scaffolding the connection string by using the Name= syntax to read it from configuration - see https://go.microsoft.com/fwlink/?linkid=2131148. For more guidance on storing connection strings, see https://go.microsoft.com/fwlink/?LinkId=723263.
        => optionsBuilder.UseNpgsql("Server=127.0.0.1;Port=5432;Database=QCSYS;User Id=postgres;Password=abc123@;");


Scaffold-DbContext "Data Source=DESKTOP-HIEDF2R;Initial Catalog=QCSYS;Persist Security Info=True;User ID=sa;Password=123456;TrustServerCertificate=true;" Microsoft.EntityFrameworkCore.SqlServer -OutputDir Models -Context "qcsysContext" -UseDatabaseNames
