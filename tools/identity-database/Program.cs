using Microsoft.Data.SqlClient;
using System.Text.Json;

if (args.Length < 2 || args[0] is not ("inspect" or "preflight" or "install"))
    throw new ArgumentException("Usage: IdentityDatabase <inspect|preflight|install> <identity-directory> [receipt.json] [001-login-identity|002-run-evidence|003-trust-authority]");
try
{
    string root = Path.GetFullPath(args[1]);
    string migration = args.Length > 3 ? args[3] : "001-login-identity";
    if (migration is not ("001-login-identity" or "002-run-evidence" or "003-trust-authority")) throw new ArgumentException();
    string relative = args[0] switch {
        "inspect" => "sql/inspect-schema.sql",
        "preflight" => $"sql/migrations/{migration}.rollback.sql",
        _ => $"sql/migrations/{migration}.commit.sql"
    };
    string sql = await File.ReadAllTextAsync(Path.Combine(root,relative));
    if (args[0] == "preflight")
    {
        const string ending = "\nROLLBACK TRANSACTION;\nEND TRY";
        sql = sql.Replace("\r\n","\n");
        if (sql.Split(ending).Length != 2) throw new Exception();
        string checksFile = migration switch {
            "001-login-identity" => "sql/verify-login-contract.sql",
            "002-run-evidence" => "sql/verify-run-evidence-contract.sql",
            _ => "sql/verify-trust-authority-contract.sql"
        };
        string checks = await File.ReadAllTextAsync(Path.Combine(root,checksFile));
        sql = sql.Replace(ending,"\n"+checks+ending);
    }
    string value = Environment.GetEnvironmentVariable("SFX_IDENTITY_CONNECTION_STRING") ?? throw new Exception();
    var target = new SqlConnectionStringBuilder(value);
    if (!string.Equals(target.InitialCatalog,"sfx-identity",StringComparison.OrdinalIgnoreCase)) throw new Exception();
    using var connection = new SqlConnection(target.ConnectionString);
    await connection.OpenAsync();
    using var command = connection.CreateCommand();
    command.CommandText = sql; command.CommandTimeout=90;
    // No outer transaction: each migration owns its transaction and terminal action.
    using var reader = await command.ExecuteReaderAsync();
    var sets = new List<List<Dictionary<string,object?>>>();
    do
    {
        var rows = new List<Dictionary<string,object?>>();
        while (await reader.ReadAsync())
        {
            var row = new Dictionary<string,object?>();
            for(int i=0;i<reader.FieldCount;i++) row[reader.GetName(i)] = reader.IsDBNull(i) ? null : reader.GetValue(i);
            rows.Add(row);
        }
        sets.Add(rows);
    } while(await reader.NextResultAsync());
    if(sets.Count==0 || sets.All(s=>s.Count==0)) throw new Exception();
    var receipt = new { capturedAt=DateTimeOffset.UtcNow, action=args[0], migration, database="sfx-identity",
        resultSetCounts=sets.Select(s=>s.Count),resultSets=sets };
    if(args.Length>2) await File.WriteAllTextAsync(args[2],JsonSerializer.Serialize(receipt,new JsonSerializerOptions { WriteIndented=true }));
    Console.WriteLine(JsonSerializer.Serialize(new { action=args[0],resultSetCounts=sets.Select(s=>s.Count),completed=true }));
}
catch(SqlException e) { Console.Error.WriteLine($"IDENTITY_DATABASE_OPERATION_FAILED sqlNumber={e.Number} line={e.LineNumber}"); Environment.Exit(1); }
catch { Console.Error.WriteLine("IDENTITY_DATABASE_OPERATION_FAILED"); Environment.Exit(1); }

