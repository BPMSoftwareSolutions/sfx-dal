
using Microsoft.Data.SqlClient;
using System.Linq.Expressions;

namespace SFX.DAL.Helpers
{
    public class QueryDetail<T>
    {
        public List<SearchCriterion<T>> SearchCriteria { get; set; }
        public int Page { get; set; }
        public int PageSize { get; set; }
        public List<OrderBy<T>> OrderByList { get; set; }

        public QueryDetail()
        {
            SearchCriteria = new List<SearchCriterion<T>>();
            OrderByList = new List<OrderBy<T>>();
            PageSize = 10;
            Page = 1;
        }

        public static string GetSqlOperator(Operator op)
        {
            return op switch
            {
                Operator.Equal => "=",
                Operator.Equals => "=",
                Operator.NotEquals => "<>",
                Operator.GreaterThan => ">",
                Operator.LessThan => "<",
                Operator.GreaterThanOrEqual => ">=",
                Operator.LessThanOrEqual => "<=",
                Operator.Like => "LIKE",
                _ => throw new ArgumentOutOfRangeException(nameof(op), op, null)
            };
        }

        public static string GetSqlDirection(SortDirection direction)
        {
            return direction switch
            {
                SortDirection.Ascending => "ASC",
                SortDirection.Descending => "DESC",
                _ => throw new ArgumentOutOfRangeException(nameof(direction), direction, null)
            };
        }

        public static void AddSearchParameters(SqlCommand command, List<SearchCriterion<T>> searchCriteria)
        {
            int index = 0;
            foreach (var criteria in searchCriteria)
            {
                object value = criteria.Value;
                if (criteria.Operator == Operator.Like)
                {
                    switch (criteria.LikeType)
                    {
                        case LikeType.StartsWith:
                            value = $"{criteria.Value}%";
                            break;
                        case LikeType.EndsWith:
                            value = $"%{criteria.Value}";
                            break;
                        case LikeType.Contains:
                        default:
                            value = $"%{criteria.Value}%";
                            break;
                    }
                }
                string parameterName = $"@{criteria.GetColumnName()}{index}";
                command.Parameters.AddWithValue(parameterName, value ?? DBNull.Value);
                index++;
            }
        }
    }

    public class OrderBy<T>
    {
        public Expression<Func<T, object>> Column { get; set; } = null!;
        public SortDirection Direction { get; set; } = SortDirection.Ascending; // Default to Ascending

        public string GetColumnName()
        {
            if (Column.Body is UnaryExpression unaryExpression && unaryExpression.Operand is MemberExpression memberExpression)
            {
                return memberExpression.Member.Name;
            }
            else if (Column.Body is MemberExpression member)
            {
                return member.Member.Name;
            }
            throw new InvalidOperationException("Invalid column expression");
        }
    }

    public class SearchCriterion<T>
    {
        public Expression<Func<T, object>> Column { get; set; } = null!;
        public Operator Operator { get; set; }
        public object Value { get; set; } = null!;
        public LikeType LikeType { get; set; } = LikeType.Contains; // Default to Contains
        public bool TrimSpaces { get; set; } = false; // Default to false

        public string GetColumnName()
        {
            if (Column.Body is UnaryExpression unaryExpression && unaryExpression.Operand is MemberExpression memberExpression)
            {
                return memberExpression.Member.Name;
            }
            else if (Column.Body is MemberExpression member)
            {
                return member.Member.Name;
            }
            throw new InvalidOperationException("Invalid column expression");
        }
    }

    public enum LikeType
    {
        StartsWith,
        EndsWith,
        Contains
    }

    public enum Operator
    {
        Equal,
        Equals,
        NotEquals,
        GreaterThan,
        LessThan,
        GreaterThanOrEqual,
        LessThanOrEqual,
        Like
    }

    public enum SortDirection
    {
        Ascending,
        Descending
    }
}
