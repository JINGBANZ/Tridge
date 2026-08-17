# Model inventory dates as civil days

Purchase Day and Expiry Day are timezone-independent calendar dates, while creation, modification,
and stock-event occurrence remain instants. Persist the calendar values as signed Gregorian day
ordinals relative to 1970-01-01; this prevents a shared item's displayed purchase or expiry day from
changing when members use different time zones.
