import Foundation

public enum ComputerHistoryMarkdownRenderer {
    public static func render(_ memory: ComputerHistoryDayMemory) -> String {
        ComputerHistoryAgentContextRenderer.render(memory).markdown
    }
}
