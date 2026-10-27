function Show { param([string]$FilePath, [string[]]$Arguments = @()) ($Arguments | ForEach-Object { "[$_]" }) -join ' ' }
$one = @('src/a.ts')
$two = @('src/a.ts', 'src/b.ts')
"1 file  (as written, line 759): " + (Show git @('stash', 'push', '--', @($one)))
"2 files (as written, line 759): " + (Show git @('stash', 'push', '--', @($two)))
"2 files (proposed fix)        : " + (Show git (@('stash', 'push', '--') + @($two)))
