Here is the fix:

```js
if (!session) {
  redirect("/login");
}
```
