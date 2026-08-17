# Make saved item names immutable

An item's normalized identity and displayed name become immutable when the item is saved; users
correct names during review or delete and add the item again. Permanent exact-name merge links then
cannot split after stock operations have been applied, avoiding a distributed rename and quantity-
allocation protocol in the first sharing release.
