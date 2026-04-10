#!chezscheme
(library (gitsafe patterns)
  (export make-secret-pattern
          secret-pattern?
          secret-pattern-id
          secret-pattern-name
          secret-pattern-severity
          secret-pattern-pregexp
          secret-pattern-validator
          secret-pattern-description
          all-patterns
          patterns-by-severity)
  (import (except (chezscheme)
                  make-hash-table hash-table?
                  sort sort!
                  printf fprintf
                  path-extension path-absolute?
                  with-input-from-string with-output-to-string
                  iota 1+ 1-
                  partition
                  make-date make-time)
          (jerboa prelude)
          (std pregexp))

  ;; --- Secret pattern struct ---
  (defstruct secret-pattern
    (id          ;; symbol
     name        ;; string
     severity    ;; symbol: 'critical | 'high | 'medium | 'low
     pregexp     ;; compiled pregexp
     validator   ;; #f | (string -> boolean)
     description ;; string
     ))

  ;; --- Helpers ---
  (def (has-prefix? str prefix)
    (and (>= (string-length str) (string-length prefix))
         (string=? (substring str 0 (string-length prefix)) prefix)))

  (def (entropy-above? str threshold)
    ;; inline entropy to avoid circular dep — compute Shannon entropy
    (let ([len (string-length str)])
      (if (<= len 0)
        #f
        (let ([freqs (make-vector 256 0)])
          (let loop ([i 0])
            (when (< i len)
              (let ([b (char->integer (string-ref str i))])
                (vector-set! freqs b (+ 1 (vector-ref freqs b))))
              (loop (+ i 1))))
          (let ([n (inexact len)])
            (let loop ([i 0] [e 0.0])
              (if (>= i 256)
                (> e threshold)
                (let ([c (vector-ref freqs i)])
                  (if (= c 0)
                    (loop (+ i 1) e)
                    (let ([p (/ (inexact c) n)])
                      (loop (+ i 1) (- e (* p (log p 2))))))))))))))

  (def (not-placeholder? str)
    ;; Reject common test/example placeholder strings
    (not (or (pregexp-match "^[Xx]+$" str)
             (pregexp-match "^[Aa]+$" str)
             (pregexp-match "(?i:example|placeholder|your[_-]?key|test|fake|dummy|replace)" str)
             (string=? str "")
             (< (string-length str) 8))))

  ;; --- CRITICAL patterns ---

  (def pat-aws-access-key
    (make-secret-pattern
      'aws-access-key
      "AWS Access Key ID"
      'critical
      (pregexp "(?:^|[^A-Za-z0-9])((?:AKIA|ABIA|ACCA|ASIA)[A-Z0-9]{16})(?:[^A-Za-z0-9]|$)")
      (lambda (m) (= (string-length m) 20))
      "AWS IAM Access Key ID (starts with AKIA/ABIA/ACCA/ASIA)"))

  (def pat-aws-secret-key
    (make-secret-pattern
      'aws-secret-key
      "AWS Secret Access Key"
      'critical
      (pregexp "(?i:aws[_-]?secret[_-]?(?:access[_-]?)?key|secret[_-]?key)\\s*[=:]\\s*['\"]?([A-Za-z0-9/+=]{40})['\"]?")
      (lambda (m) (= (string-length m) 40))
      "AWS Secret Access Key (40-char base64)"))

  (def pat-github-pat
    (make-secret-pattern
      'github-pat
      "GitHub Personal Access Token"
      'critical
      (pregexp "gh[pousr]_[A-Za-z0-9_]{36,255}")
      (lambda (m) (has-prefix? m "gh"))
      "GitHub PAT (classic: ghp_, gho_, ghu_, ghs_, ghr_)"))

  (def pat-github-fine-grained
    (make-secret-pattern
      'github-fine-grained
      "GitHub Fine-Grained PAT"
      'critical
      (pregexp "github_pat_[A-Za-z0-9_]{22,255}")
      #f
      "GitHub Fine-Grained Personal Access Token"))

  (def pat-openai-key
    (make-secret-pattern
      'openai-api-key
      "OpenAI API Key"
      'critical
      (pregexp "sk-[A-Za-z0-9]{20}T3BlbkFJ[A-Za-z0-9]{20}")
      (lambda (m) (string-contains m "T3BlbkFJ"))
      "OpenAI API Key (contains T3BlbkFJ marker)"))

  (def pat-openai-project-key
    (make-secret-pattern
      'openai-project-key
      "OpenAI Project Key"
      'critical
      (pregexp "sk-proj-[A-Za-z0-9_-]{40,200}")
      #f
      "OpenAI Project-scoped API Key"))

  (def pat-anthropic-key
    (make-secret-pattern
      'anthropic-api-key
      "Anthropic API Key"
      'critical
      (pregexp "sk-ant-(?:api03-)?[A-Za-z0-9_-]{90,200}")
      (lambda (m) (has-prefix? m "sk-ant-"))
      "Anthropic Claude API Key"))

  (def pat-stripe-secret
    (make-secret-pattern
      'stripe-secret
      "Stripe Secret Key"
      'critical
      (pregexp "[sr]k_live_[A-Za-z0-9]{24,99}")
      #f
      "Stripe live secret or restricted key"))

  (def pat-private-key-pem
    (make-secret-pattern
      'private-key-pem
      "Private Key (PEM)"
      'critical
      (pregexp "-----BEGIN (?:RSA |DSA |EC |OPENSSH |PGP )?PRIVATE KEY-----")
      #f
      "PEM-encoded private key block"))

  ;; --- HIGH patterns ---

  (def pat-generic-api-key
    (make-secret-pattern
      'generic-api-key
      "Generic API Key Assignment"
      'high
      (pregexp "(?i:(api[_-]?key|apikey|api[_-]?secret|access[_-]?key))\\s*[=:]\\s*['\"]([A-Za-z0-9_/+=.\\-]{16,})['\"]")
      (lambda (m) (and (not-placeholder? m) (entropy-above? m 3.5)))
      "Key/value assignment with high-entropy value"))

  (def pat-generic-secret
    (make-secret-pattern
      'generic-secret
      "Generic Secret Assignment"
      'high
      (pregexp "(?i:(secret|token|password|passwd|credential|auth[_-]?key))\\s*[=:]\\s*['\"]([^'\"\\s]{8,})['\"]")
      (lambda (m) (and (not-placeholder? m) (entropy-above? m 3.5)))
      "Assignment of secret/token/password with high-entropy value"))

  (def pat-generic-bearer
    (make-secret-pattern
      'generic-bearer
      "Bearer Token"
      'high
      (pregexp "(?i:bearer)\\s+([A-Za-z0-9_.~+/=\\-]{20,})")
      (lambda (m) (entropy-above? m 3.0))
      "HTTP Authorization Bearer token"))

  (def pat-slack-token
    (make-secret-pattern
      'slack-token
      "Slack Token"
      'high
      (pregexp "xox[bpors]-[A-Za-z0-9\\-]{10,250}")
      #f
      "Slack API token (xoxb-, xoxp-, xoxo-, xoxr-, xoxs-)"))

  (def pat-slack-webhook
    (make-secret-pattern
      'slack-webhook
      "Slack Webhook URL"
      'high
      (pregexp "hooks\\.slack\\.com/services/T[A-Z0-9]{8,10}/B[A-Z0-9]{8,10}/[A-Za-z0-9]{20,30}")
      #f
      "Slack incoming webhook URL"))

  (def pat-google-api-key
    (make-secret-pattern
      'google-api-key
      "Google API Key"
      'high
      (pregexp "AIza[A-Za-z0-9_\\-]{35}")
      (lambda (m) (= (string-length m) 39))
      "Google Cloud / Maps API key (starts with AIza)"))

  (def pat-twilio-api-key
    (make-secret-pattern
      'twilio-api-key
      "Twilio API Key"
      'high
      (pregexp "SK[a-f0-9]{32}")
      (lambda (m) (= (string-length m) 34))
      "Twilio API key SID"))

  (def pat-sendgrid-key
    (make-secret-pattern
      'sendgrid-api-key
      "SendGrid API Key"
      'high
      (pregexp "SG\\.[A-Za-z0-9_\\-]{22}\\.[A-Za-z0-9_\\-]{43}")
      #f
      "SendGrid API key (SG. format)"))

  (def pat-mailgun-key
    (make-secret-pattern
      'mailgun-api-key
      "Mailgun API Key"
      'high
      (pregexp "key-[a-f0-9]{32}")
      (lambda (m) (= (string-length m) 36))
      "Mailgun private API key"))

  (def pat-npm-token
    (make-secret-pattern
      'npm-token
      "NPM Token"
      'high
      (pregexp "npm_[A-Za-z0-9]{36}")
      #f
      "NPM publish/automation token"))

  (def pat-pypi-token
    (make-secret-pattern
      'pypi-token
      "PyPI Token"
      'high
      (pregexp "pypi-[A-Za-z0-9_\\-]{50,}")
      #f
      "PyPI upload token"))

  (def pat-jwt
    (make-secret-pattern
      'jwt
      "JSON Web Token"
      'high
      (pregexp "eyJ[A-Za-z0-9_\\-]{10,}\\.[A-Za-z0-9_\\-]{10,}\\.[A-Za-z0-9_\\-]{10,}")
      #f
      "JWT (three-part base64url token starting with eyJ)"))

  (def pat-basic-auth-url
    (make-secret-pattern
      'basic-auth-url
      "Credentials in URL"
      'high
      (pregexp "[a-z+]+://([^:@\\s]+):([^:@\\s]+)@[^\\s\"']+")
      (lambda (m) (not (or (string=? m "localhost")
                           (string=? m "user")
                           (string=? m "username"))))
      "URL with embedded user:password credentials"))

  ;; --- MEDIUM patterns ---

  (def pat-connection-string
    (make-secret-pattern
      'connection-string
      "Database Connection String"
      'medium
      (pregexp "(?i:(?:mongodb|postgres|postgresql|mysql|redis|amqp|mssql))://[^:@\\s]+:[^:@\\s]+@[^\\s\"']+")
      #f
      "Database/broker connection string with credentials"))

  (def pat-high-entropy-hex
    (make-secret-pattern
      'high-entropy-hex
      "High-Entropy Hex String"
      'medium
      (pregexp "[0-9a-f]{40,}")
      (lambda (m) (entropy-above? m 3.0))
      "Long hex string with high entropy (possible API key or token)"))

  (def pat-high-entropy-base64
    (make-secret-pattern
      'high-entropy-base64
      "High-Entropy Base64 String"
      'medium
      (pregexp "[A-Za-z0-9+/]{40,}={0,2}")
      (lambda (m) (entropy-above? m 4.0))
      "Long base64 string with high entropy (possible encoded secret)"))

  ;; --- Pattern registry ---

  (def *all-patterns*
    (list
      ;; Critical
      pat-aws-access-key
      pat-aws-secret-key
      pat-github-pat
      pat-github-fine-grained
      pat-openai-key
      pat-openai-project-key
      pat-anthropic-key
      pat-stripe-secret
      pat-private-key-pem
      ;; High
      pat-generic-api-key
      pat-generic-secret
      pat-generic-bearer
      pat-slack-token
      pat-slack-webhook
      pat-google-api-key
      pat-twilio-api-key
      pat-sendgrid-key
      pat-mailgun-key
      pat-npm-token
      pat-pypi-token
      pat-jwt
      pat-basic-auth-url
      ;; Medium
      pat-connection-string
      pat-high-entropy-hex
      pat-high-entropy-base64))

  (def (all-patterns) *all-patterns*)

  (def (patterns-by-severity sev)
    (filter (lambda (p) (eq? (secret-pattern-severity p) sev))
            *all-patterns*))

) ;; end library
