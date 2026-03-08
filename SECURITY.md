# Security Policy

## Supported Versions

We actively support the latest version of this project.

| Version | Supported          |
| ------- | ------------------ |
| latest  | :white_check_mark: |
| < latest| :x:                |

## Reporting a Vulnerability

We take security vulnerabilities seriously. If you discover a security issue, please report it responsibly.

### How to Report

1. **Do NOT** open a public GitHub issue
2. Use GitHub's Private Security Advisory feature:
   - Go to the repository's Security tab
   - Click "Report a vulnerability"
   - Fill out the advisory form

### What to Include

Please include the following information in your report:

- Description of the vulnerability
- Steps to reproduce the issue
- Potential impact
- Suggested fix (if you have one)

### Response Timeline

- **Initial Response:** Within 48 hours
- **Status Update:** Within 7 days
- **Fix Timeline:** Varies by severity
  - Critical: Within 7 days
  - High: Within 14 days
  - Medium: Within 30 days
  - Low: Within 90 days

### Disclosure Policy

- We will work with you to understand and fix the vulnerability
- We request that you do not publicly disclose the vulnerability until we have released a fix
- We will credit you in the security advisory (unless you prefer to remain anonymous)

## Security Best Practices

When using this project:

1. **Keep Dependencies Updated:** Regularly update to the latest version
2. **Use Environment Variables:** Never hardcode secrets or API keys
3. **Review Permissions:** Only grant necessary permissions
4. **Enable 2FA:** Use two-factor authentication on your GitHub account
5. **Monitor Alerts:** Watch for Dependabot security alerts

## Security Features

This project implements the following security measures:

- Automated dependency scanning via Dependabot
- Regular security audits
- Input validation and sanitization
- Path traversal protection
- Rate limiting
- Secure secret management

## Contact

For general security questions, please open a discussion in the repository.

---

*Last Updated: November 25, 2025*
