#!/bin/bash

echo "# Starting concatenation of .csproj and .cs files..." > code-base.md
echo "## Concatenating .csproj files" >> code-base.md
echo "```" > code-base.cs
concat_files.sh src/ .csproj 
cat combined_output.txt >> code-base.cs 
echo "```" > code-base.cs

echo "## Concatenating .cs files" >> code-base.md
echo "```" >> code-base.cs
concat_files.sh src/ .cs 
cat combined_output.txt >> code-base.cs 
echo "```" >> code-base.cs

echo "✅ Concatenation complete. Output written to code-base.md and code-base.cs" >> code-base.md

echo "## Restoring and building the project..." >> code-base.md
echo "```" >> code-base.md
dotnet restore >> code-base.cs 
echo "```" >> code-base.cs

echo "## Building the project..." >> code-base.md
dotnet build >> code-base.cs

echo "```" >> code-base.md
echo "✅ Project restored and built successfully." >> code-base.md
