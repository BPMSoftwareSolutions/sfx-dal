#nullable enable

using System.Data;
using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Data.SqlClient;

namespace SFX.Semantics
{
    /// <summary>A raw source read and how it was captured, before projection.</summary>
    public sealed record SemanticRead(SemanticSource Source, SemanticCapture Capture);

    /// <summary>Raised when a read basis cannot be established; no snapshot is produced.</summary>
    public sealed class SemanticReadException : Exception
    {
        /// <summary>Creates the exception.</summary>
        public SemanticReadException(string message, Exception? inner = null)
            : base(message, inner)
        {
        }
    }

    /// <summary>
    /// Reads SideFX semantic objects through their installed reader procedures without changing
    /// the estate. Every read runs on one connection in one SNAPSHOT transaction: the basis, the
    /// reader definition digest, the document and the transaction's own log-record count are all
    /// observed inside it, and the transaction is always rolled back. The client calls only
    /// readers named by generated contracts; it has no write path.
    /// </summary>
    public sealed class SemanticReadClient
    {
        /// <summary>The machine-level connection setting used by the estate DAL.</summary>
        public const string DefaultConnectionVariable = "sidefx-connection-string";

        private readonly string _connectionString;

        /// <summary>Creates a client over a connection string. The string is never logged or returned.</summary>
        public SemanticReadClient(string connectionString, string expectedDatabase = "sidefx", int commandTimeoutSeconds = 120)
        {
            if (string.IsNullOrWhiteSpace(connectionString))
            {
                throw new ArgumentException("A connection string is required.", nameof(connectionString));
            }

            _connectionString = connectionString;
            ExpectedDatabase = expectedDatabase;
            CommandTimeoutSeconds = commandTimeoutSeconds;
        }

        /// <summary>The database every read must target; any other database is refused.</summary>
        public string ExpectedDatabase { get; }

        /// <summary>Timeout for each SQL command.</summary>
        public int CommandTimeoutSeconds { get; }

        /// <summary>Creates a client from an environment setting without printing it.</summary>
        public static SemanticReadClient FromEnvironment(string variable = DefaultConnectionVariable, EnvironmentVariableTarget target = EnvironmentVariableTarget.Machine)
        {
            string? setting = Environment.GetEnvironmentVariable(variable, target);
            if (string.IsNullOrWhiteSpace(setting))
            {
                throw new SemanticReadException("The connection setting '" + variable + "' (" + target + ") is absent.");
            }

            return new SemanticReadClient(setting);
        }

        /// <summary>Reads and projects one capability. Pass an estate pin to read a specific basis; otherwise the current estate is resolved inside the same snapshot.</summary>
        public async Task<CapabilitySnapshot> ReadCapabilityAsync(string capabilityId, long? estateModelPk = null, CancellationToken cancellationToken = default)
        {
            SemanticRead read = await ReadCapabilitySourceAsync(capabilityId, estateModelPk, cancellationToken).ConfigureAwait(false);
            return CapabilitySnapshot.Project(read.Source, read.Capture);
        }

        /// <summary>Reads one capability's source document without projecting it.</summary>
        public Task<SemanticRead> ReadCapabilitySourceAsync(string capabilityId, long? estateModelPk = null, CancellationToken cancellationToken = default)
        {
            ArgumentNullException.ThrowIfNull(capabilityId);
            return ReadInSnapshotAsync(
                CapabilityProjectionContract.Procedure,
                estateModelPk,
                (connection, transaction, basis, token) => CapabilitySource.ReadAsync(connection, transaction, capabilityId, basis, CommandTimeoutSeconds, token),
                cancellationToken);
        }

        /// <summary>
        /// Returns the installed definition digests of a procedure, read in a rolled-back snapshot:
        /// UTF-16LE (the estate's stored form) and UTF-8 (the research receipt's form). Null when not visible.
        /// </summary>
        public async Task<(string? Utf16Le, string? Utf8)> ReadDefinitionDigestsAsync(string procedure, CancellationToken cancellationToken = default)
        {
            await using SqlConnection connection = await OpenVerifiedAsync(cancellationToken).ConfigureAwait(false);
            using SqlTransaction transaction = connection.BeginTransaction(IsolationLevel.Snapshot);
            try
            {
                string? text = await ReadDefinitionAsync(connection, transaction, procedure, cancellationToken).ConfigureAwait(false);
                return text == null ? (null, null) : (Digest("sha256-utf16le:", Encoding.Unicode.GetBytes(text)), Digest(string.Empty, Encoding.UTF8.GetBytes(text)));
            }
            finally
            {
                transaction.Rollback();
            }
        }

        private async Task<SemanticRead> ReadInSnapshotAsync(
            string procedure,
            long? estateModelPk,
            Func<SqlConnection, SqlTransaction, long, CancellationToken, Task<SemanticSource>> read,
            CancellationToken cancellationToken)
        {
            DateTimeOffset capturedAt = DateTimeOffset.UtcNow;
            Stopwatch watch = Stopwatch.StartNew();
            await using SqlConnection connection = await OpenVerifiedAsync(cancellationToken).ConfigureAwait(false);
            string database = connection.Database;
            SqlTransaction transaction = connection.BeginTransaction(IsolationLevel.Snapshot);
            bool rolledBack = false;
            try
            {
                long basis = estateModelPk ?? await ResolveCurrentEstateAsync(connection, transaction, cancellationToken).ConfigureAwait(false);
                string? definition = await ReadDefinitionAsync(connection, transaction, procedure, cancellationToken).ConfigureAwait(false);
                SemanticSource source = await read(connection, transaction, basis, cancellationToken).ConfigureAwait(false);
                long? logRecords = await ReadLogRecordsAsync(connection, transaction, cancellationToken).ConfigureAwait(false);
                transaction.Rollback();
                rolledBack = true;
                watch.Stop();
                return new SemanticRead(source, new SemanticCapture
                {
                    Database = database,
                    ReaderDefinitionDigest = definition == null ? null : Digest("sha256-utf16le:", Encoding.Unicode.GetBytes(definition)),
                    Isolation = "SNAPSHOT",
                    TransactionOutcome = "ROLLED_BACK",
                    DatabaseLogRecords = logRecords,
                    CapturedAtUtc = capturedAt,
                    ElapsedMilliseconds = watch.ElapsedMilliseconds,
                });
            }
            finally
            {
                if (rolledBack == false)
                {
                    // A reader error can leave the transaction doomed or already ended; either way nothing commits.
                    try
                    {
                        transaction.Rollback();
                    }
                    catch (InvalidOperationException)
                    {
                    }
                    catch (SqlException)
                    {
                    }
                }

                transaction.Dispose();
            }
        }

        private async Task<SqlConnection> OpenVerifiedAsync(CancellationToken cancellationToken)
        {
            var connection = new SqlConnection(_connectionString);
            try
            {
                await connection.OpenAsync(cancellationToken).ConfigureAwait(false);
                using var command = new SqlCommand("SELECT DB_NAME(), snapshot_isolation_state_desc FROM sys.databases WHERE database_id = DB_ID();", connection) { CommandTimeout = CommandTimeoutSeconds };
                using SqlDataReader reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
                if (await reader.ReadAsync(cancellationToken).ConfigureAwait(false) == false || string.Equals(reader.GetString(0), ExpectedDatabase, StringComparison.Ordinal) == false)
                {
                    throw new SemanticReadException("The connection does not target the expected database '" + ExpectedDatabase + "'.");
                }

                if (string.Equals(reader.GetString(1), "ON", StringComparison.Ordinal) == false)
                {
                    throw new SemanticReadException("SNAPSHOT isolation is not enabled, so a single consistent read basis cannot be established.");
                }

                return connection;
            }
            catch
            {
                await connection.DisposeAsync().ConfigureAwait(false);
                throw;
            }
        }

        private async Task<long> ResolveCurrentEstateAsync(SqlConnection connection, SqlTransaction transaction, CancellationToken cancellationToken)
        {
            using var command = new SqlCommand("SELECT estate_model_pk FROM source.current_model WHERE singleton_id = 1;", connection, transaction) { CommandTimeout = CommandTimeoutSeconds };
            object? value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
            if (value is not long estate)
            {
                throw new SemanticReadException("The estate has no current model, so no read basis can be pinned.");
            }

            return estate;
        }

        private async Task<string?> ReadDefinitionAsync(SqlConnection connection, SqlTransaction transaction, string procedure, CancellationToken cancellationToken)
        {
            using var command = new SqlCommand("SELECT OBJECT_DEFINITION(OBJECT_ID(@name));", connection, transaction) { CommandTimeout = CommandTimeoutSeconds };
            command.Parameters.Add(new SqlParameter("@name", SqlDbType.NVarChar, 512) { Value = procedure });
            return await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) as string;
        }

        // Log records this transaction generated in the estate database. A read must generate none;
        // null when the connection may not observe transaction state.
        private async Task<long?> ReadLogRecordsAsync(SqlConnection connection, SqlTransaction transaction, CancellationToken cancellationToken)
        {
            const string sql = "SELECT COUNT_BIG(*), SUM(t.database_transaction_log_record_count) FROM sys.dm_tran_database_transactions t "
                + "JOIN sys.dm_tran_current_transaction c ON c.transaction_id = t.transaction_id WHERE t.database_id = DB_ID();";
            try
            {
                using var command = new SqlCommand(sql, connection, transaction) { CommandTimeout = CommandTimeoutSeconds };
                using SqlDataReader reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
                if (await reader.ReadAsync(cancellationToken).ConfigureAwait(false) == false || reader.GetInt64(0) == 0 || reader.IsDBNull(1))
                {
                    return null;
                }

                return Convert.ToInt64(reader.GetValue(1), CultureInfo.InvariantCulture);
            }
            catch (SqlException)
            {
                return null;
            }
        }

        private static string Digest(string prefix, byte[] bytes) => prefix + Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    }
}
