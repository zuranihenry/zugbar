import SwiftUI
import ZugbarCore

/// The user's coach on a train and the platform sector it stops in, e.g. "Coach 8 · seat 42 · sector C",
/// or a button to enter it.
struct SeatRow: View {
    @Bindable var editor: SeatEditor
    let field: SeatEditor.Field
    let seat: Seat?
    /// Where the train stops at the station in question, once DB's coach sequence is loaded.
    let sequence: CoachSequence?
    let save: (Seat?) -> Void
    @Environment(\.strings) private var strings

    var body: some View {
        if editor.editing == field {
            HStack(spacing: 6) {
                Image(systemName: "train.side.middle.car").foregroundStyle(.secondary)
                TextField(strings.coachField, text: $editor.coach)
                    .frame(width: 64)
                TextField(strings.seatField, text: $editor.number)
                    .frame(width: 64)
                Button(action: commit) { Image(systemName: "checkmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .disabled(Seat(typedCoach: editor.coach, seat: editor.number) == nil)
                    .help(strings.save)
                    .accessibilityLabel(strings.save)
                Button { editor.editing = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(strings.cancel)
                    .accessibilityLabel(strings.cancel)
            }
            .textFieldStyle(.roundedBorder)
            .font(.callout)
            .onSubmit(commit)
            .onExitCommand { editor.editing = nil }
        } else if let seat {
            HStack(spacing: 6) {
                Image(systemName: "train.side.middle.car").foregroundStyle(.secondary)
                label(for: seat)
                Spacer(minLength: 4)
                Button { editor.edit(field, seat: seat) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help(strings.changeCoach)
                    .accessibilityLabel(strings.changeCoach)
                Button { save(nil) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help(strings.removeCoach)
                    .accessibilityLabel(strings.removeCoach)
            }
            .font(.caption)
            .help(strings.coachHint)
        } else {
            Button { editor.edit(field, seat: nil) } label: { Label(strings.addCoach, systemImage: "train.side.middle.car") }
                .buttonStyle(.borderless)
                .font(.caption)
                .help(strings.coachHint)
        }
    }

    /// "Coach 8 · seat 42 · sector C", with the sector stressed: it's where to stand.
    private func label(for seat: Seat) -> Text {
        let text = Text(strings.seat(seat))
        guard let sequence else { return text }
        guard let coach = sequence.coach(seat.coach) else { return Text("\(text) · \(Text(strings.coachMissing).foregroundStyle(.orange))") }
        if coach.closed { return Text("\(text) · \(Text(strings.coachClosed).foregroundStyle(.orange))") }
        guard let sector = coach.sector else { return text }
        return Text("\(text) · \(Text(strings.sector(sector)).fontWeight(.semibold))")
    }

    private func commit() {
        guard let seat = Seat(typedCoach: editor.coach, seat: editor.number) else { return }
        save(seat)
        editor.editing = nil
    }
}
