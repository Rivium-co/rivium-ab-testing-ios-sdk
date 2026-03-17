import Foundation

/// Evaluates targeting rules to determine if a user should be included in an experiment
internal class TargetingEngine {

    /// Evaluate targeting rules against user attributes
    /// Returns true if user matches all rules (AND logic)
    func evaluate(rules: [String: AnyCodable]?, userAttributes: [String: Any]?) -> Bool {
        guard let rules = rules, !rules.isEmpty else {
            return true // No rules means everyone is included
        }

        for (key, rule) in rules {
            if !evaluateRule(key: key, rule: rule.value, attributes: userAttributes ?? [:]) {
                return false
            }
        }

        return true
    }

    private func evaluateRule(key: String, rule: Any, attributes: [String: Any]) -> Bool {
        let value = attributes[key]

        if let ruleDict = rule as? [String: Any] {
            return evaluateComplexRule(value: value, rule: ruleDict)
        }

        // Simple equality check
        return isEqual(value, rule)
    }

    private func evaluateComplexRule(value: Any?, rule: [String: Any]) -> Bool {
        // equals operator
        if let expected = rule["equals"] {
            return isEqual(value, expected)
        }

        // notEquals operator
        if let expected = rule["notEquals"] {
            return !isEqual(value, expected)
        }

        // in operator
        if let expectedList = rule["in"] as? [Any] {
            return expectedList.contains { isEqual(value, $0) }
        }

        // notIn operator
        if let expectedList = rule["notIn"] as? [Any] {
            return !expectedList.contains { isEqual(value, $0) }
        }

        // greaterThan operator
        if let expected = rule["greaterThan"] {
            return compareNumbers(value, expected) > 0
        }

        // lessThan operator
        if let expected = rule["lessThan"] {
            return compareNumbers(value, expected) < 0
        }

        // greaterThanOrEqual operator
        if let expected = rule["greaterThanOrEqual"] {
            return compareNumbers(value, expected) >= 0
        }

        // lessThanOrEqual operator
        if let expected = rule["lessThanOrEqual"] {
            return compareNumbers(value, expected) <= 0
        }

        // contains operator (for strings)
        if let expected = rule["contains"] as? String,
           let strValue = value as? String {
            return strValue.contains(expected)
        }

        // regex operator
        if let pattern = rule["regex"] as? String,
           let strValue = value as? String {
            do {
                let regex = try NSRegularExpression(pattern: pattern)
                let range = NSRange(strValue.startIndex..., in: strValue)
                return regex.firstMatch(in: strValue, range: range) != nil
            } catch {
                return false
            }
        }

        // exists operator
        if let shouldExist = rule["exists"] as? Bool {
            return shouldExist ? (value != nil) : (value == nil)
        }

        // AND logic
        if let andRules = rule["and"] as? [[String: Any]] {
            return andRules.allSatisfy { evaluateComplexRule(value: value, rule: $0) }
        }

        // OR logic
        if let orRules = rule["or"] as? [[String: Any]] {
            return orRules.contains { evaluateComplexRule(value: value, rule: $0) }
        }

        return false
    }

    private func isEqual(_ a: Any?, _ b: Any?) -> Bool {
        if a == nil && b == nil { return true }
        guard let a = a, let b = b else { return false }

        switch (a, b) {
        case let (a as String, b as String): return a == b
        case let (a as Int, b as Int): return a == b
        case let (a as Double, b as Double): return a == b
        case let (a as Bool, b as Bool): return a == b
        case let (a as NSNumber, b as NSNumber): return a == b
        default: return false
        }
    }

    private func compareNumbers(_ a: Any?, _ b: Any?) -> Int {
        guard let numA = (a as? NSNumber)?.doubleValue,
              let numB = (b as? NSNumber)?.doubleValue else {
            return 0
        }
        if numA < numB { return -1 }
        if numA > numB { return 1 }
        return 0
    }
}
