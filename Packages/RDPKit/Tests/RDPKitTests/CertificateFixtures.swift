/// Throwaway certificates for tests, made with OpenSSL. Their private keys
/// were deleted when they were made. Valid from 12 November 2026: the root
/// for ten years, the others until 14 December 2027.
enum CertificateFixtures {
    /// A certificate authority that no system trusts.
    static let root = """
    -----BEGIN CERTIFICATE-----
    MIIDWTCCAkGgAwIBAgIUaEa2KaNczS15cxoUfW6ErND36tkwDQYJKoZIhvcNAQEL
    BQAwNDEWMBQGA1UECgwNVmlzdGFyYSBUZXN0czEaMBgGA1UEAwwRVmlzdGFyYSBU
    ZXN0IFJvb3QwHhcNMjYxMTEyMDExMzQ1WhcNMzYxMTA5MDExMzQ1WjA0MRYwFAYD
    VQQKDA1WaXN0YXJhIFRlc3RzMRowGAYDVQQDDBFWaXN0YXJhIFRlc3QgUm9vdDCC
    ASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAJHJd7lAcj0oFDXwroA3EQJ8
    yrz6TN1tijhauCf2UApQynBiYwbXRZPDVScqi6pNNPlgxSSOlW56R9Kt4LZsvC3u
    TkZt1a0IebjJWojLV3wFCeozRJ9WQWhTKcFvKYklE90onBmDgm/7+qTGfBJ9AA16
    RgpsEZoVRoezhMN13OprcJAj5zqCVCsWaAxae9oBQZLRmwYwCH9jNc0Y0hQcT/FU
    tdE4w9n/kzL0Vk76nishhV6L/j+gCWcyXJxqcH8HJlnvOnauq+woU/GaxSBf+Gbl
    yXBI8SKc7az2tcjhnM6itZzD7GfmbtE+ypCtw0o8xHipFuCzxXl9Oks4EgfwqQ8C
    AwEAAaNjMGEwHQYDVR0OBBYEFOZeSJZMdh8pYt6mf03mXzJyn1+HMB8GA1UdIwQY
    MBaAFOZeSJZMdh8pYt6mf03mXzJyn1+HMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0P
    AQH/BAQDAgEGMA0GCSqGSIb3DQEBCwUAA4IBAQBy1C6ETTRGoclV0s3w4GlVaj2d
    tzkOrGcBuUS1dP1Vmlghv51Sphdfj45FptdfTj/8yvXWUcshn+ovXvFloRy4hI3O
    OIkoXF4oJZLQWNWlRjSzzemBXr807cwmhcyPv9Z4O01Plt/ivIXwBZUu+aqfcfA3
    6Cxcgu772SLHjJ5oQ4TthfvgTRHUYtMlCX7au4UK2DxQCjrg5epfNI1ma3trQ+sA
    fXgTlZ5In5SxtiLRwWSJkEElANeqhbHHptXYq+HhKbLt7x4L0NFUhd2RlVD5+6bV
    OLUbKV2KTqrcXjFfwoJYV3rcBwblYHvt0DMMzo40qO4r2o9QgO8mDWMsLier
    -----END CERTIFICATE-----
    """

    /// Issued by `root` for build01.example.com, as a TLS server certificate.
    static let server = """
    -----BEGIN CERTIFICATE-----
    MIIDjzCCAnegAwIBAgIUK8jLypOgnv15UxpCaoPlca5xJcEwDQYJKoZIhvcNAQEL
    BQAwNDEWMBQGA1UECgwNVmlzdGFyYSBUZXN0czEaMBgGA1UEAwwRVmlzdGFyYSBU
    ZXN0IFJvb3QwHhcNMjYxMTEyMDExMzQ1WhcNMjcxMjE0MDExMzQ1WjA2MRYwFAYD
    VQQKDA1WaXN0YXJhIFRlc3RzMRwwGgYDVQQDDBNidWlsZDAxLmV4YW1wbGUuY29t
    MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAmId7F+HWvjJdoagLJosP
    jZPKTumADVAwwOsa7cpca766oIkZhqBk8r9bOiIQeTciF3zK93Xgs5m6sz8R/a1G
    r/FSL9X1v9ahTI203IN7q8lB3lyRwLJHa3x29x+zyHij0XWi8q34Xmo+FaLRTcIx
    LU7Bb2Lb0QG+HW23aXApmnkdlqe1VvyGVjCNABN6Xf7fAEWHMD/l12m20NghDO3W
    wp8N1Trzl+dbjAaLG1h0TCMO+9NMJY2+F0ycWjTxu/AT1vHyQfoB96ieiYKTCnme
    Khqr2Us2UY59ra00c97BfKM1Z9m59SCerBnBVinwKm/CnTwJs83afkdAQ3NJFH99
    wQIDAQABo4GWMIGTMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgWgMBMGA1Ud
    JQQMMAoGCCsGAQUFBwMBMB4GA1UdEQQXMBWCE2J1aWxkMDEuZXhhbXBsZS5jb20w
    HQYDVR0OBBYEFF9JOywu5h2vpk1z8rcC8+9DoM2eMB8GA1UdIwQYMBaAFOZeSJZM
    dh8pYt6mf03mXzJyn1+HMA0GCSqGSIb3DQEBCwUAA4IBAQAWLf3tPbBU6z34sNMI
    w38LvipldbpAtu2UQkWG1RLQQ9WGDJlBaBGOJH9BLGhgT/Epu+uEKDax1DoqUJZM
    0ZFBI+cxsL84cJJJZ9oixK/g74cbzMHAqqw0wmqBm6FxjPs53mDOdns4/MyvQ/lE
    /YFn2L89LOCWz4v7jV6W2xP+CMycWpSFfPyFFvce7yOg+/gZGWWIbYzGhAH5wWn9
    sysCS+A1lcJmSsM0ocayknyLJsLllpLTX2Euz/f5QITUdVxuVsVtBuluisOUf/k4
    R7ObczX9tLuomftJwPYBQ5i8VtTwfVDP9kL/MN+gdrIsTlVNZ/K3qFs4LxWxnbJu
    xQhm
    -----END CERTIFICATE-----
    """

    /// Self-signed, as a Windows computer presents by default.
    static let selfSigned = """
    -----BEGIN CERTIFICATE-----
    MIIDRTCCAi2gAwIBAgIUALtL7W9wrIGEYmy0x6nUK6nh7GowDQYJKoZIhvcNAQEL
    BQAwGTEXMBUGA1UEAwwOV0lOLVNFTEZTSUdORUQwHhcNMjYxMTEyMDExMzQ1WhcN
    MjcxMjE0MDExMzQ1WjAZMRcwFQYDVQQDDA5XSU4tU0VMRlNJR05FRDCCASIwDQYJ
    KoZIhvcNAQEBBQADggEPADCCAQoCggEBALMENBk+qGuvz7QbRUSqzE4riAFW79CX
    XgrffawBcsDFUOhScXtJmY62KPAIiLrym567+htcTPWjFjxNNdsdUI11EfVbQjNp
    0l1uftlolTpmtD8PnSoccop+EeQxgqWP3rBjfLndH32Tpki90K/vkcVyU0tJeQhK
    leQ3ilgqZzQSLIPc1oh8BmN4Yv7z4Ce+Ud/l4AFf/Yl2uEOVm+Ymya2Bl5ClwZAE
    YOxgvTrqLDpyetWw9sAVWI3D3JQWvVshEWUB4fvLMKS0D0TBqVo4iJhbhAaG4hiT
    D/sBZZJH2Tn8oUxJEs+pbGIqeiiwB4pdlH6U5OwyEftYd/3qns376DkCAwEAAaOB
    hDCBgTAdBgNVHQ4EFgQUhh8PKGCqxJWA8l1afZAxwXNw7lAwHwYDVR0jBBgwFoAU
    hh8PKGCqxJWA8l1afZAxwXNw7lAwDwYDVR0TAQH/BAUwAwEB/zAZBgNVHREEEjAQ
    gg5XSU4tU0VMRlNJR05FRDATBgNVHSUEDDAKBggrBgEFBQcDATANBgkqhkiG9w0B
    AQsFAAOCAQEAAvD/1w+9skmZ/UL/lJmPCAUw6FbfmDTmbtxu6av2RH/u6jUsE3a1
    Rsfk9pnG21YnaxXZ7vMA8ge+4wp7Z+lKhuJXsCrRZC73MeNrVmid7fmwcbY+d5Mb
    o+TDew2lz+OJ4hRVtBYFcJCya4j83V2ix6Mds41EdUy9ZJG6rmYU5OY5l8JuvkGT
    MLdQVkTqbEPM3Ki6Xm9L+cHKcWlmejTm1QIMrm0ZwH0RAmdxNXz5NmX7gNBzRQAI
    dy5MVHK88yZiJa6c9SO7bwePY5hMD+iII5c18Qc9UPZRrVcSE9x6jUAOKM1GErHb
    WJy+7PHZHCN/1c7d3+v7RsFS9dknlfnOXw==
    -----END CERTIFICATE-----
    """

    static let serverFingerprint =
        "7e:50:77:83:05:04:51:75:c6:77:0b:4e:9d:f0:c5:dd:6d:81:26:fa:7e:db:03:f2:cb:61:bb:c9:65:23:f1:5d"
    static let selfSignedFingerprint =
        "59:ec:cb:ca:69:81:f0:4a:89:dd:39:54:fc:38:57:2b:96:95:9c:b4:c3:9f:e8:0b:69:5f:26:98:42:8a:c9:43"
}
