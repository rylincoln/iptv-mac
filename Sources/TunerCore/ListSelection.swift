/// Where a list's selection goes when rows are taken out from under it.
public enum ListSelection {
    /// The selection once the rows `isRemoved` matches are taken out of `rows`. A selected row that
    /// stays stays selected. One that goes hands the selection to the row that moves up into its
    /// place (the first row after it that stays), or, with none after it, to the nearest row before
    /// it that stays; with no row left, nothing is selected. A selection that names no row in `rows`
    /// is left as it is.
    public static func afterRemoving<Row: Identifiable>(
        from rows: [Row], where isRemoved: (Row) -> Bool, selected: Row.ID?
    ) -> Row.ID? {
        guard let selected, let index = rows.firstIndex(where: { $0.id == selected }),
              isRemoved(rows[index])
        else { return selected }
        if let after = rows[(index + 1)...].first(where: { !isRemoved($0) }) { return after.id }
        return rows[..<index].last { !isRemoved($0) }?.id
    }
}
