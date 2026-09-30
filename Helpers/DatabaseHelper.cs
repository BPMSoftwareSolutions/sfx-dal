
using Microsoft.Data.SqlClient;

namespace SFX.DAL.Helpers
{
    public static class DatabaseHelper
    {
        private static readonly string? _connectionStringEnvVar;

        static DatabaseHelper()
        {
#if DEBUG
            _connectionStringEnvVar = Environment.GetEnvironmentVariable("sidefx-connection-string", EnvironmentVariableTarget.Machine);
#else
            _connectionStringEnvVar = Environment.GetEnvironmentVariable("sidefx-connection-string");
#endif
        }

        public static string GetConnectionString()
        {
            return _connectionStringEnvVar ?? throw new InvalidOperationException("Connection string environment variable \"sidefx-connection-string\" is not set.");
        }

        public static bool TestConnection()
        {
            using (var connection = new SqlConnection(GetConnectionString()))
            {
                try
                {
                    connection.Open();
                    return true;
                }
                catch (Exception)
                {
                    return false;
                }
            }
        }
    }
}
