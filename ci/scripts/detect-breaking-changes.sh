#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_REF="${GITHUB_BASE_REF:-main}"

echo "🔍 DataFusion Breaking Changes Detection"
echo "Comparing against: $BASE_REF"

echo "Installing cargo-semver-checks..."
cargo install cargo-semver-checks

detect_datafusion_breaking_changes() {
    local breaking_changes_found=false

    echo "📋 Checking DataFusion-specific API rules..."

    echo "Checking public APIs..."
    if ! cargo semver-checks check-release \
        --manifest-path datafusion/Cargo.toml \
        --config .cargo/semver-checks.toml \
        --exclude-api-path "datafusion::internal" \
        --exclude-api-path "datafusion::test_util"; then

        echo "❌ Breaking changes detected in public APIs"
        breaking_changes_found=true
    fi

    echo "Checking LogicalPlan stability..."
    if check_logical_plan_changes; then
        echo "❌ Breaking changes detected in LogicalPlan"
        breaking_changes_found=true
    fi

    echo "Checking DataFrame API..."
    if check_dataframe_api_changes; then
        echo "❌ Breaking changes detected in DataFrame API"
        breaking_changes_found=true
    fi

    echo "Checking SQL parser compatibility..."
    if check_sql_parser_changes; then
        echo "❌ Breaking changes detected in SQL parser"
        breaking_changes_found=true
    fi

    return $breaking_changes_found
}

check_logical_plan_changes() {
    echo "  - Checking LogicalPlan enum variants..."

    cargo run --bin analyze-logical-plan-changes -- \
        --base-ref="$BASE_REF" \
        --current-ref="HEAD"
}

check_dataframe_api_changes() {
    echo "  - Checking DataFrame public methods..."

    # Check if DataFrame public methods were removed or changed
    git diff "$BASE_REF"..HEAD -- datafusion/src/dataframe/mod.rs | \
    grep -E "^-.*pub (fn|struct|enum)" && return 0 || return 1
}

check_sql_parser_changes() {
    echo "  - Checking SQL keyword changes..."

    git diff "$BASE_REF"..HEAD -- datafusion/sql/src/keywords.rs | \
    grep -E "^-.*," && return 0 || return 1
}

generate_breaking_changes_report() {
    local output_file="breaking-changes-report.md"

    cat > "$output_file" << EOF
# 🚨 Breaking Changes Report

## Summary
Breaking changes detected in this PR that require the \`api-change\` label.

## DataFusion API Stability Guidelines
Per the [API Health Policy](https://datafusion.apache.org/contributor-guide/specification/api-health-policy.html):

### Changes Detected:
EOF

    echo "### Semver Analysis:" >> "$output_file"
    cargo semver-checks check-release --output-format=markdown >> "$output_file" 2>/dev/null || true

    echo "### DataFusion-Specific Analysis:" >> "$output_file"

    if git diff "$BASE_REF"..HEAD --name-only | grep -q "src/logical_expr"; then
        echo "- ⚠️  LogicalExpr changes detected" >> "$output_file"
    fi

    if git diff "$BASE_REF"..HEAD --name-only | grep -q "src/dataframe"; then
        echo "- ⚠️  DataFrame API changes detected" >> "$output_file"
    fi

    cat >> "$output_file" << EOF

## Required Actions:
1. Add the \`api-change\` label to this PR
2. Update CHANGELOG.md with breaking change details
3. Consider adding deprecation warnings before removal
4. Update migration guide if needed

## Approval Requirements:
- Breaking changes require approval from a DataFusion maintainer
- Consider if this change is necessary or if a deprecation path exists
EOF

    echo "📋 Report generated: $output_file"
}

main() {
    if detect_datafusion_breaking_changes; then
        echo "✅ No breaking changes detected"
        echo "BREAKING_CHANGES_DETECTED=false" >> $GITHUB_ENV
    else
        echo "❌ Breaking changes detected!"
        echo "BREAKING_CHANGES_DETECTED=true" >> $GITHUB_ENV

        generate_breaking_changes_report

        if [ -n "$GITHUB_TOKEN" ] && [ -n "$GITHUB_REPOSITORY" ]; then
            echo "💬 Adding PR comment..."
            gh pr comment --body-file breaking-changes-report.md
        fi

        exit 1
    fi
}

main "$@"