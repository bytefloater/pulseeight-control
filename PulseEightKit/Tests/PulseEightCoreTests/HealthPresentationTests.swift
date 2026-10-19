import Foundation
import Testing
@testable import PulseEightCore
import PulseEightKit

@Suite struct HealthPresentationTests {
    let strings = Strings(language: .english)

    @Test(arguments: [
        (0, "0s"), (45, "45s"), (60, "1m"), (899, "14m"), (3_600, "1h 0m"), (3_725, "1h 2m"),
        (86_400, "1d 0h"), (90_061, "1d 1h"), (-5, "0s"),
    ])
    func durationsShowTheLargestUnits(seconds: Int, expected: String) {
        #expect(Presentation.durationText(seconds: seconds, strings) == expected)
    }

    @Test func temperaturesDropNeedlessDecimals() {
        #expect(Presentation.temperatureText(31, strings) == "31 °C")
        #expect(Presentation.temperatureText(31.5, strings) == "31.5 °C")
        #expect(Presentation.temperatureText(31.26, strings) == "31.3 °C", "rounds to one place")
    }

    @Test func voltagesAlwaysShowTwoPlacesAndFlagARailOutOfRange() {
        #expect(Presentation.voltageText(PowerRail(name: "12V", volts: 12.256533), strings) == "12.26 V")
        #expect(Presentation.voltageText(PowerRail(name: "5V", volts: 5), strings) == "5.00 V")
        #expect(Presentation.voltageText(PowerRail(name: "5V", ok: false, volts: 4.1), strings) == "4.10 V (out of range)")
    }

    @Test func rowsListStatusUptimePartsTemperaturesAndRails() {
        let health = SystemHealth(
            statusMessage: "Healthy",
            rails: [PowerRail(name: "12V", volts: 12.25), PowerRail(name: "1V top", volts: 0)],
            temperatures: [32, 36.5],
            components: [
                HealthComponent(kind: .powerSupply(1), status: 0, message: "Present & Healthy"),
                HealthComponent(kind: .inputModules, status: 2, message: ""),
            ],
            updateState: 6, uptime: 3_725)
        let rows = Presentation.healthRows(health, strings)

        #expect(rows.map(\.label) == [
            "Status", "Uptime", "Power supply 1", "Input modules", "Temperature 1", "Temperature 2",
            "Supply rail 12V", "Supply rail 1V top", "Firmware update state",
        ])
        #expect(rows.map(\.value) == [
            "Healthy", "1h 2m", "Present & Healthy", "2", "32 °C", "36.5 °C", "12.25 V", "0.00 V", "6",
        ])
    }

    @Test func rowsSayWhichAreInGoodOrderAndWhichGroupTheyBelongTo() {
        let health = SystemHealth(
            status: 1, statusMessage: "Degraded",
            rails: [PowerRail(name: "12V", volts: 12.25), PowerRail(name: "5V", ok: false, volts: 4.1)],
            temperatures: [32],
            components: [
                HealthComponent(kind: .powerSupply(1), status: 0, message: "Healthy"),
                HealthComponent(kind: .outputModules, status: 2, message: "Fault"),
            ],
            uptime: 90)
        let rows = Presentation.healthRows(health, strings)

        func row(_ label: String) -> LabeledValue { rows.first { $0.label == label }! }
        #expect(row("Status").ok == false)
        #expect(row("Uptime").ok == nil)
        #expect(row("Power supply 1").ok == true)
        #expect(row("Output modules").ok == false)
        #expect(row("Temperature 1").ok == nil)
        #expect(row("Supply rail 12V").ok == true)
        #expect(row("Supply rail 5V").ok == false)
        #expect(rows.filter { $0.group == "diagnostics" }.map(\.label) == ["Temperature 1", "Supply rail 12V", "Supply rail 5V"])
        #expect(rows.filter { $0.group == "health" }.map(\.label) == ["Status", "Uptime", "Power supply 1", "Output modules"])
    }

    @Test func theCloudLinkJoinsTheHealthRows() {
        let rows = Presentation.healthRows(
            health: SystemHealth(statusMessage: "Healthy", uptime: 90),
            monitoring: MonitoringSettings(cloudConnected: true, lastContact: 1213, installerID: "1924"), strings)
        #expect(rows.map(\.label) == ["Status", "Uptime", "Cloud connection", "Last contact", "Installer ID"])
        #expect(rows.map(\.value) == ["Healthy", "1m", "Connected", "20m ago", "1924"])
        #expect(rows.map(\.group) == ["health", "health", "health", "health", "health"])
        #expect(rows[2].ok == true, "the cloud connection is judged, so it gets a tick or a warning")
        #expect(rows[3].ok == nil && rows[4].ok == nil)
    }

    @Test func aMatrixThatCannotReachTheCloudIsFlagged() {
        let rows = Presentation.healthRows(health: nil, monitoring: MonitoringSettings(cloudConnected: false, lastContact: 7200), strings)
        #expect(rows.map(\.label) == ["Cloud connection", "Last contact"], "no installer id was reported, so no row")
        #expect(rows.map(\.value) == ["Not connected", "2h 0m ago"])
        #expect(rows.first?.ok == false)
    }

    @Test func theCloudRowsStandOnTheirOwnWithoutAHealthReportAndTheOldCallStillWorks() {
        #expect(Presentation.healthRows(health: nil, monitoring: nil, strings).isEmpty)
        let health = SystemHealth(statusMessage: "Healthy")
        #expect(Presentation.healthRows(health, strings) == Presentation.healthRows(health: health, monitoring: nil, strings))
    }

    @Test func anEmptyReportGivesNoRows() {
        #expect(Presentation.healthRows(SystemHealth(), strings).isEmpty)
    }
}
