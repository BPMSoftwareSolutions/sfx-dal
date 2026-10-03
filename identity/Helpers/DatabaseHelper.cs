
using Microsoft.Data.SqlClient;

namespace SFX.Identity.DAL.Helpers
{
    public static class DatabaseHelper
    {
        private static readonly string? _connectionStringEnvVar;

        static DatabaseHelper()
        {
#if DEBUG
            _connectionStringEnvVar = Environment.GetEnvironmentVariable("SFX_IDENTITY_CONNECTION_STRING", EnvironmentVariableTarget.Process);
#else
            _connectionStringEnvVar = Environment.GetEnvironmentVariable("SFX_IDENTITY_CONNECTION_STRING");
#endif
        }

        public static string GetConnectionString()
        {
            return _connectionStringEnvVar ?? throw new InvalidOperationException("Connection string environment variable \"SFX_IDENTITY_CONNECTION_STRING\" is not set.");
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
