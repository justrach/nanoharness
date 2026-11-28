//! Bounded metadata for cloud artifacts stored on CodeGraff (`artifact.codegraff.com`).
//! HTML/SVG/Markdown payloads live in R2 behind gateway CRUD APIs; session docs carry
//! only validated metadata and canonical https://codegraff.com/a/<id> links (never signed tokens).

pub const ARTIFACT_TITLE_MAX_CHARS: usize = 200;
pub const ARTIFACT_ID_LEN: usize = 28; // "art-" + 24 lowercase hex chars
pub const ARTIFACT_URL_PREFIX: &str = "https://codegraff.com/a/";

pub fn is_valid_artifact_id(id: &str) -> bool {
    if id.len() != ARTIFACT_ID_LEN || !id.starts_with("art-") {
        return false;
    }
    id[4..]
        .bytes()
        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

pub fn is_valid_artifact_format(format: &str) -> bool {
    matches!(format, "html" | "svg" | "markdown")
}

pub fn is_valid_artifact_visibility(visibility: &str) -> bool {
    matches!(visibility, "private" | "public")
}

/// Shared ingress/storage validator for durable `MessagePart::Artifact` records.
pub fn validate_artifact(
    artifact_id: &str,
    title: &str,
    format: &str,
    visibility: &str,
    url: &str,
) -> Result<(), &'static str> {
    if !is_valid_artifact_id(artifact_id) {
        return Err("artifactId must be art- followed by 24 lowercase hex characters");
    }
    let trimmed = title.trim();
    if trimmed.is_empty() || trimmed.chars().count() > ARTIFACT_TITLE_MAX_CHARS {
        return Err("artifact title must be nonblank and at most 200 characters");
    }
    if !is_valid_artifact_format(format) {
        return Err("artifact format must be html, svg, or markdown");
    }
    if !is_valid_artifact_visibility(visibility) {
        return Err("artifact visibility must be private or public");
    }
    let expected = format!("{ARTIFACT_URL_PREFIX}{artifact_id}");
    if url != expected {
        return Err("artifact url must match canonical https://codegraff.com/a/<artifactId>");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "art-0123456789abcdef01234567";

    #[test]
    fn valid_artifact_passes_and_rejects_bad_fields_or_signed_urls() {
        let url = format!("https://codegraff.com/a/{ID}");
        assert!(validate_artifact(ID, "System Diagram", "html", "private", &url).is_ok());
        assert!(validate_artifact(ID, "Logo", "svg", "public", &url).is_ok());
        assert!(validate_artifact(ID, &"界".repeat(200), "markdown", "private", &url).is_ok());

        // Reject bad id, uppercase hex, whitespace/long title, bad format/visibility, off-origin or token URLs
        assert!(validate_artifact("art-0123", "Ok", "html", "private", &url).is_err());
        assert!(
            validate_artifact(
                "art-0123456789ABCDEF01234567",
                "Ok",
                "html",
                "private",
                "https://codegraff.com/a/art-0123456789ABCDEF01234567"
            )
            .is_err()
        );
        assert!(validate_artifact(ID, "   \n", "html", "private", &url).is_err());
        assert!(validate_artifact(ID, &"a".repeat(201), "html", "private", &url).is_err());
        assert!(validate_artifact(ID, "Ok", "pdf", "private", &url).is_err());
        assert!(validate_artifact(ID, "Ok", "html", "unlisted", &url).is_err());
        assert!(
            validate_artifact(ID, "Ok", "html", "private", &format!("{url}?t=secret")).is_err()
        );
        assert!(validate_artifact(ID, "Ok", "html", "private", "https://evil.example/a").is_err());
    }
}
