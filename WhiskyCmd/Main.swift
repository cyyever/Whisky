//
//  Main.swift
//  WhiskyCmd
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import ArgumentParser
import Foundation
import SwiftyTextTable
import WhiskyKit

@main
struct Whisky: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "A CLI interface for Whisky.",
        subcommands: [List.self,
                      Run.self])
}

extension Whisky {
    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List existing bottles.")

        mutating func run() throws {
            var bottlesList = BottleData()
            let bottles = bottlesList.loadBottles()

            let nameCol = TextTableColumn(header: "Name")
            let winVerCol = TextTableColumn(header: "Windows Version")
            let pathCol = TextTableColumn(header: "Path")

            var table = TextTable(columns: [nameCol, winVerCol, pathCol])
            for bottle in bottles {
                table.addRow(values: [bottle.settings.name,
                                      bottle.settings.windowsVersion.pretty(),
                                      bottle.url.prettyPath()])
            }

            print(table.render())
        }
    }

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run a program with Whisky.")

        @Argument var bottleName: String
        @Argument var path: String
        @Argument var args: [String] = []

        mutating func run() async throws {
            var bottlesList = BottleData()
            let bottles = bottlesList.loadBottles()

            guard let bottle = bottles.first(where: { $0.settings.name == bottleName }) else {
                throw ValidationError("A bottle with that name doesn't exist.")
            }

            // Single launch entry: `launch` runs `prepareForLaunch` (DXVK + Steam
            // CEF wrapper) itself, then runs the program in the bottle.
            let url = URL(fileURLWithPath: path)
            let program = Program(url: url, bottle: bottle)
            await program.launch()
        }
    }

}
