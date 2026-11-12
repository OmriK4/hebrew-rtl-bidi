```bash
git checkout -b fix/login-redirect
npm install
npm run lint
npm test
git add -A
git commit -m "fix login redirect"
git push -u origin fix/login-redirect
gh pr create --fill
gh pr checks --watch
gh pr merge --squash
```
