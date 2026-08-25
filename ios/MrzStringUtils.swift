/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Utilities for dealing with recognized strings
*/

import Foundation

private let tdThreeFirstRegex = "P.[A-Z0<]{3}([A-Z0]+<)+<([A-Z0]+<)+<+"
private let tdThreeSecondRegex = "[A-Z0-9]{1,9}<?[0-9O]{1}[A-Z0<]{3}[0-9]{7}(M|F|<)[0-9O]{7}[A-Z0-9<]+"
private let tdThreeMrzRegex = "P.[A-Z0<]{3}([A-Z0]+<)+<([A-Z0]+<)+<+\n[A-Z0-9]{1,9}<?[0-9O]{1}[A-Z0<]{3}[0-9]{7}(M|F|<)[0-9O]{7}[A-Z0-9<]+"

func calcCheckDigit(_ value: String) -> String {
  let uppercaseLetters = CharacterSet.uppercaseLetters
  let digits = CharacterSet.decimalDigits
  let weights = [7, 3, 1]
  var total = 0
    
  for (index, character) in value.enumerated() {
    let unicodeScalar = character.unicodeScalars.first!
    let charValue: Int
  
    if uppercaseLetters.contains(unicodeScalar) {
      charValue = Int(10 + unicodeScalar.value) - 65
    } else if digits.contains(unicodeScalar) {
      charValue = Int(String(character))!
    } else if character == "<" {
      charValue = 0
    } else {
      return "<"
    }
  
    total += (charValue * weights[index % 3])
  }
  total = total % 10
  return String(total)
}

func validateMRZ(_ mrz: String) -> Bool {
  // print("Validating: " + mrz)
  var len = 44
  let documentNumberWithCheck = mrz.suffix(len).prefix(10)
  len = len - 10 - 3
  let birthDateWithCheck = mrz.suffix(len).prefix(7)
  len = len - 7 - 1
  let expiryDateWithCheck = mrz.suffix(len).prefix(7)
  len = len - 7
  let optionalDataWithCheck = mrz.suffix(len).prefix(15)
  
  // see https://www.icao.int/publications/Documents/9303_p4_cons_en.pdf
  
  /* Composite check digit for characters of
   machine readable data of the lower line
   in positions 1 to 10, 14 to 20 and 22 to
   43, including values for letters that are
   a part of the number fields and their
   check digits.
   */
  let secondLineWithCheck = documentNumberWithCheck +
    birthDateWithCheck +
    expiryDateWithCheck +
    optionalDataWithCheck +
    mrz.suffix(1)
  
  if (calcCheckDigit(String(documentNumberWithCheck.prefix(9))) != String(documentNumberWithCheck.suffix(1))) {
    // print("fail docnum check: " + documentNumberWithCheck)
    return false
  }
  if (calcCheckDigit(String(birthDateWithCheck.prefix(6))) != String(birthDateWithCheck.suffix(1))) {
    // print("fail bdate check: " + birthDateWithCheck)
    return false
  }
  if (calcCheckDigit(String(expiryDateWithCheck.prefix(6))) != String(expiryDateWithCheck.suffix(1))) {
    // print("fail expdate check: " + expiryDateWithCheck)
    return false
  }
  // We intentionally verify the 4 TD3 checksums:
  // document number, birth date, expiry date, and final/composite.
  if (calcCheckDigit(String(secondLineWithCheck.prefix(39))) != String(secondLineWithCheck.suffix(1))) {
    // print("fail line check: " + secondLineWithCheck)
    return false
  }
  return true
}

extension String {
  var stripped: String {
    let okayChars = Set("ABCDEFGHIJKLKMNOPQRSTUVWXYZ1234567890<")
    return self.filter {okayChars.contains($0) }
  }
}

func parseTd3Mrz(from strings: [String]) -> String? {
  var firstLine: String?
  var secondLine: String?

  for string in strings {
    let normalized = string.uppercased().stripped

    if firstLine == nil,
       let firstMatchRange = normalized.range(of: tdThreeFirstRegex, options: .regularExpression, range: nil, locale: nil) {
      let candidate = String(normalized[firstMatchRange])
      if candidate.count == 44 {
        firstLine = candidate
      }
    }

    if secondLine == nil,
       let secondMatchRange = normalized.range(of: tdThreeSecondRegex, options: .regularExpression, range: nil, locale: nil) {
      let candidate = String(normalized[secondMatchRange])
      if candidate.count == 44 {
        secondLine = candidate
      }
    }

    guard let first = firstLine, let second = secondLine else { continue }

    let combined = "\(first)\n\(second)"
    let looksLikeTd3 = combined.range(of: tdThreeMrzRegex, options: .regularExpression, range: nil, locale: nil) != nil
    if looksLikeTd3 && validateMRZ(combined) {
      return combined
    }
  }

  return nil
}
