#nullable enable

using System.Collections.Immutable;
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

    /// <summary>The estate row a read basis pins, as registered in <c>source.estate_model</c>.</summary>
    public sealed record SemanticEstateBasis(long EstateModelPk, long? EstateSnapshotPk, string? PublicationState, string? MappingManifestDigest, bool Pinned);

    /// <summary>How a read session ended: its basis, the estate log records it generated, and its outcome.</summary>
    public sealed record SemanticSessionOutcome(string Database, SemanticEstateBasis Basis, long? DatabaseLogRecords, string TransactionOutcome, long ElapsedMilliseconds);

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
    /// the estate. A <see cref="SemanticReadSession"/> holds one connection and one SNAPSHOT
    /// transaction, so every reader in it sees one consistent basis; the transaction is always rolled
    /// back. The client calls only readers named by generated contracts; it has no write path.
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

        /// <summary>
        /// Opens a read session at a basis. A pinned estate must be registered in source.estate_model;
        /// otherwise the current estate is resolved inside the same snapshot. An estate number is a
        /// mutable pointer, so each read also records the digests of what it depended on.
        /// </summary>
        public async Task<SemanticReadSession> OpenSessionAsync(long? estateModelPk = null, CancellationToken cancellationToken = default)
        {
            var watch = Stopwatch.StartNew();
            var connection = new SqlConnection(_connectionString);
            SqlTransaction? transaction = null;
            try
            {
                await connection.OpenAsync(cancellationToken).ConfigureAwait(false);
                using (var command = new SqlCommand("SELECT DB_NAME(), snapshot_isolation_state_desc FROM sys.databases WHERE database_id = DB_ID();", connection) { CommandTimeout = CommandTimeoutSeconds })
                using (SqlDataReader reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false))
                {
                    if (await reader.ReadAsync(cancellationToken).ConfigureAwait(false) == false || string.Equals(reader.GetString(0), ExpectedDatabase, StringComparison.Ordinal) == false)
                    {
                        throw new SemanticReadException("The connection does not target the expected database '" + ExpectedDatabase + "'.");
                    }

                    if (string.Equals(reader.GetString(1), "ON", StringComparison.Ordinal) == false)
                    {
                        throw new SemanticReadException("SNAPSHOT isolation is not enabled, so a single consistent read basis cannot be established.");
                    }
                }

                transaction = connection.BeginTransaction(IsolationLevel.Snapshot);
                SemanticEstateBasis basis = await ResolveBasisAsync(connection, transaction, estateModelPk, cancellationToken).ConfigureAwait(false);
                return new SemanticReadSession(connection, transaction, basis, CommandTimeoutSeconds, watch);
            }
            catch
            {
                if (transaction != null)
                {
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

                    transaction.Dispose();
                }

                await connection.DisposeAsync().ConfigureAwait(false);
                throw;
            }
        }

        /// <summary>Reads and projects one capability in its own session.</summary>
        public async Task<CapabilitySnapshot> ReadCapabilityAsync(string capabilityId, long? estateModelPk = null, CancellationToken cancellationToken = default)
        {
            SemanticRead read = await ReadCapabilitySourceAsync(capabilityId, estateModelPk, cancellationToken).ConfigureAwait(false);
            return CapabilitySnapshot.Project(read.Source, read.Capture);
        }

        /// <summary>Reads one capability's source document in its own session, without projecting it.</summary>
        public async Task<SemanticRead> ReadCapabilitySourceAsync(string capabilityId, long? estateModelPk = null, CancellationToken cancellationToken = default)
        {
            await using SemanticReadSession session = await OpenSessionAsync(estateModelPk, cancellationToken).ConfigureAwait(false);
            SemanticRead read = await session.ReadCapabilityAsync(capabilityId, cancellationToken).ConfigureAwait(false);
            SemanticSessionOutcome outcome = await session.CompleteAsync(cancellationToken).ConfigureAwait(false);
            return read with { Capture = read.Capture with { DatabaseLogRecords = outcome.DatabaseLogRecords, TransactionOutcome = outcome.TransactionOutcome } };
        }

        /// <summary>
        /// Returns the installed definition digests of a procedure, read in a rolled-back snapshot:
        /// UTF-16LE (the estate's stored form) and UTF-8 (the research receipt's form). Null when not visible.
        /// </summary>
        public async Task<(string? Utf16Le, string? Utf8)> ReadDefinitionDigestsAsync(string procedure, CancellationToken cancellationToken = default)
        {
            await using SemanticReadSession session = await OpenSessionAsync(null, cancellationToken).ConfigureAwait(false);
            string? text = await session.ReadDefinitionAsync(procedure, cancellationToken).ConfigureAwait(false);
            await session.CompleteAsync(cancellationToken).ConfigureAwait(false);
            return text == null ? (null, null) : (SemanticReadSession.Digest("sha256-utf16le:", Encoding.Unicode.GetBytes(text)), SemanticReadSession.Digest(string.Empty, Encoding.UTF8.GetBytes(text)));
        }

        private async Task<SemanticEstateBasis> ResolveBasisAsync(SqlConnection connection, SqlTransaction transaction, long? pinned, CancellationToken cancellationToken)
        {
            long estate;
            if (pinned is { } value)
            {
                estate = value;
            }
            else
            {
                using var current = new SqlCommand("SELECT estate_model_pk FROM source.current_model WHERE singleton_id = 1;", connection, transaction) { CommandTimeout = CommandTimeoutSeconds };
                if (await current.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) is not long resolved)
                {
                    throw new SemanticReadException("The estate has no current model, so no read basis can be pinned.");
                }

                estate = resolved;
            }

            using var command = new SqlCommand("SELECT estate_snapshot_pk, publication_state, mapping_manifest_digest FROM source.estate_model WHERE estate_model_pk = @estate;", connection, transaction)
            {
                CommandTimeout = CommandTimeoutSeconds,
            };
            command.Parameters.Add(new SqlParameter("@estate", SqlDbType.BigInt) { Value = estate });
            using SqlDataReader reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
            if (await reader.ReadAsync(cancellationToken).ConfigureAwait(false) == false)
            {
                throw new SemanticReadException("Estate " + estate.ToString(CultureInfo.InvariantCulture) + " is not registered in source.estate_model; no read basis exists.");
            }

            return new SemanticEstateBasis(
                estate,
                reader.IsDBNull(0) ? null : reader.GetInt64(0),
                reader.IsDBNull(1) ? null : reader.GetString(1),
                reader.IsDBNull(2) ? null : Convert.ToHexString((byte[])reader.GetValue(2)).ToLowerInvariant(),
                pinned != null);
        }
    }

    /// <summary>
    /// One connection, one SNAPSHOT transaction, one basis. Every read in the session sees the same
    /// committed state. Completing (or disposing) the session rolls the transaction back.
    /// </summary>
    public sealed class SemanticReadSession : IAsyncDisposable
    {
        private readonly SqlConnection _connection;
        private readonly SqlTransaction _transaction;
        private readonly int _timeout;
        private readonly Stopwatch _watch;
        private SemanticSessionOutcome? _outcome;

        internal SemanticReadSession(SqlConnection connection, SqlTransaction transaction, SemanticEstateBasis basis, int timeout, Stopwatch watch)
        {
            _connection = connection;
            _transaction = transaction;
            _timeout = timeout;
            _watch = watch;
            Basis = basis;
            Database = connection.Database;
        }

        /// <summary>The estate row this session reads at.</summary>
        public SemanticEstateBasis Basis { get; }

        /// <summary>The database name.</summary>
        public string Database { get; }

        /// <summary>Reads one capability's details document, pinning its selected version digest.</summary>
        public Task<SemanticRead> ReadCapabilityAsync(string capabilityId, CancellationToken cancellationToken = default)
        {
            ArgumentNullException.ThrowIfNull(capabilityId);
            return ReadAsync(CapabilityProjectionContract.Procedure, async token =>
            {
                SemanticSource source = await CapabilitySource.ReadAsync(_connection, _transaction, capabilityId, Basis.EstateModelPk, _timeout, token).ConfigureAwait(false);
                return (source, await PinCapabilityAsync(capabilityId, token).ConfigureAwait(false));
            }, cancellationToken);
        }

        /// <summary>Reads one capability's declared model invocations, pinning its selected version digest.</summary>
        public Task<SemanticRead> ReadModelInvocationsAsync(string capabilityId, CancellationToken cancellationToken = default)
        {
            ArgumentNullException.ThrowIfNull(capabilityId);
            return ReadAsync(ModelInvocationsProjectionContract.Procedure, async token =>
            {
                SemanticSource source = await ModelInvocationsSource.ReadAsync(_connection, _transaction, capabilityId, Basis.EstateModelPk, _timeout, token).ConfigureAwait(false);
                return (source, await PinCapabilityAsync(capabilityId, token).ConfigureAwait(false));
            }, cancellationToken);
        }

        /// <summary>Reads one provider's details result sets.</summary>
        public Task<SemanticRead> ReadProviderAsync(string providerId, CancellationToken cancellationToken = default)
        {
            ArgumentNullException.ThrowIfNull(providerId);
            return ReadAsync(ProviderProjectionContract.Procedure, async token =>
            {
                SemanticSource source = await ProviderSource.ReadAsync(_connection, _transaction, providerId, Basis.EstateModelPk, _timeout, token).ConfigureAwait(false);
                return (source, ImmutableArray<SemanticDependency>.Empty);
            }, cancellationToken);
        }

        /// <summary>Rolls the session back and reports the estate log records it generated (zero for a read).</summary>
        public async Task<SemanticSessionOutcome> CompleteAsync(CancellationToken cancellationToken = default)
        {
            if (_outcome != null)
            {
                return _outcome;
            }

            long? logRecords = await ReadLogRecordsAsync(cancellationToken).ConfigureAwait(false);
            _transaction.Rollback();
            _watch.Stop();
            _outcome = new SemanticSessionOutcome(Database, Basis, logRecords, "ROLLED_BACK", _watch.ElapsedMilliseconds);
            return _outcome;
        }

        /// <inheritdoc />
        public async ValueTask DisposeAsync()
        {
            if (_outcome == null)
            {
                try
                {
                    _transaction.Rollback();
                }
                catch (InvalidOperationException)
                {
                }
                catch (SqlException)
                {
                }
            }

            _transaction.Dispose();
            await _connection.DisposeAsync().ConfigureAwait(false);
        }

        internal async Task<string?> ReadDefinitionAsync(string procedure, CancellationToken cancellationToken)
        {
            using var command = new SqlCommand("SELECT OBJECT_DEFINITION(OBJECT_ID(@name));", _connection, _transaction) { CommandTimeout = _timeout };
            command.Parameters.Add(new SqlParameter("@name", SqlDbType.NVarChar, 512) { Value = procedure });
            return await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) as string;
        }

        internal static string Digest(string prefix, byte[] bytes) => prefix + Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

        private async Task<SemanticRead> ReadAsync(string procedure, Func<CancellationToken, Task<(SemanticSource Source, ImmutableArray<SemanticDependency> Pinned)>> read, CancellationToken cancellationToken)
        {
            if (_outcome != null)
            {
                throw new InvalidOperationException("The read session is complete.");
            }

            DateTimeOffset capturedAt = DateTimeOffset.UtcNow;
            var watch = Stopwatch.StartNew();
            string? definition = await ReadDefinitionAsync(procedure, cancellationToken).ConfigureAwait(false);
            (SemanticSource source, ImmutableArray<SemanticDependency> pinned) = await read(cancellationToken).ConfigureAwait(false);
            long? logRecords = await ReadLogRecordsAsync(cancellationToken).ConfigureAwait(false);
            watch.Stop();
            return new SemanticRead(source, new SemanticCapture
            {
                Database = Database,
                ReaderDefinitionDigest = definition == null ? null : Digest("sha256-utf16le:", Encoding.Unicode.GetBytes(definition)),
                Isolation = "SNAPSHOT",
                TransactionOutcome = "OPEN",
                DatabaseLogRecords = logRecords,
                CapturedAtUtc = capturedAt,
                ElapsedMilliseconds = watch.ElapsedMilliseconds,
                PinnedRevisions = pinned,
            });
        }

        // The document names the capability's selected version by locator only; pin its digest in the same snapshot.
        private async Task<ImmutableArray<SemanticDependency>> PinCapabilityAsync(string capabilityId, CancellationToken cancellationToken)
        {
            const string sql = "SELECT cv.capability_version_pk, cv.definition_digest FROM model.capability c "
                + "JOIN model.estate_capability ec ON ec.capability_pk = c.capability_pk AND ec.estate_model_pk = @estate "
                + "JOIN model.capability_version cv ON cv.capability_version_pk = ec.capability_version_pk "
                + "WHERE c.capability_id = @id COLLATE Latin1_General_100_BIN2;";
            using var command = new SqlCommand(sql, _connection, _transaction) { CommandTimeout = _timeout };
            command.Parameters.Add(new SqlParameter("@estate", SqlDbType.BigInt) { Value = Basis.EstateModelPk });
            command.Parameters.Add(new SqlParameter("@id", SqlDbType.NVarChar, 400) { Value = capabilityId });
            using SqlDataReader reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
            if (await reader.ReadAsync(cancellationToken).ConfigureAwait(false) == false)
            {
                return ImmutableArray<SemanticDependency>.Empty;
            }

            return ImmutableArray.Create(new SemanticDependency(
                "read-session",
                "CAPABILITY_VERSION",
                capabilityId,
                reader.GetInt64(0).ToString(CultureInfo.InvariantCulture),
                reader.IsDBNull(1) ? null : Convert.ToHexString((byte[])reader.GetValue(1)).ToLowerInvariant()));
        }

        // Log records this transaction generated in the estate database. A read must generate none;
        // null when the connection may not observe transaction state.
        private async Task<long?> ReadLogRecordsAsync(CancellationToken cancellationToken)
        {
            const string sql = "SELECT COUNT_BIG(*), SUM(t.database_transaction_log_record_count) FROM sys.dm_tran_database_transactions t "
                + "JOIN sys.dm_tran_current_transaction c ON c.transaction_id = t.transaction_id WHERE t.database_id = DB_ID();";
            try
            {
                using var command = new SqlCommand(sql, _connection, _transaction) { CommandTimeout = _timeout };
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
    }
}
