I found the bug. The `getUser` function returns `undefined` when the user has not loaded yet, and the component reads `user.name` without checking that the value exists.

The cause is that the `fetch` call runs inside `useEffect`, so the first render always happens before the data arrives. The fix is to add a short guard before the return statement.

After the change, the error disappears and the page loads normally. A few more notes:

- The same pattern appears in two other components.
- I added a loading spinner so the page does not flash empty content.
- All existing tests still pass.
