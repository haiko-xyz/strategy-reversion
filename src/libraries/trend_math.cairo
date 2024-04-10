// Floor `limit` to the nearest multiple of width.
//
// # Arguments
// * `limit` - limit to floor
// * `width` - market width
//
// # Returns
// * `u32` - floored limit
pub fn floor_limit(limit: u32, width: u32) -> u32 {
    limit / width * width
}

// Ceil `limit` to the next multiple of width.
// If `limit` is already a multiple of `width`, return `limit + width`.
//
// # Arguments
// * `limit` - limit to ceil
// * `width` - market width
//
// # Returns
// * `u32` - ceiled limit
pub fn ceil_limit(limit: u32, width: u32) -> u32 {
    let ceil = (limit + width - 1) / width * width;
    if ceil == limit {
        ceil + width
    } else {
        ceil
    }
}
