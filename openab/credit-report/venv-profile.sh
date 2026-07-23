# Keep the locked CreditReportSpace runtime ahead of Debian's system Python
# even when /etc/profile resets PATH for `sh -lc` or `bash -lc`.
case ":${PATH:-}:" in
  *:/opt/credit-report/venv/bin:*) ;;
  *) PATH="/opt/credit-report/venv/bin:${PATH:-/usr/local/bin:/usr/bin:/bin}" ;;
esac
VIRTUAL_ENV=/opt/credit-report/venv
export PATH VIRTUAL_ENV
