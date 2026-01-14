# CloudXR Linux SDK Files

Place the CloudXR Linux SDK files in this directory.

## Important Notes

- **The `openxr_cloudxr.json` file should have `library_path` relative to this directory**
- The provided `openxr_cloudxr.json` should already be configured with the correct relative path: `"./libopenxr_cloudxr.so"`

## Setup Instructions

Copy all required shared library files from the CloudXR Linux SDK to this directory, including:
- The CloudXR OpenXR runtime libraries
- CloudXR client libraries
- Any dependent runtime libraries
