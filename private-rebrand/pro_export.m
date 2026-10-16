#import "REAUXHooks.h"
#import <UIKit/UIKit.h>
#import <Vision/Vision.h>
#import <PDFKit/PDFKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>

NSString *REASanitizeBrandText(NSString *input) {
    if (![input isKindOfClass:[NSString class]] || input.length == 0) return input;
    if ([input rangeOfString:@"CamScanner" options:NSCaseInsensitiveSearch].location == NSNotFound) {
        return input;
    }
    NSString *trimmed = [input stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed hasPrefix:@"http://"] || [trimmed hasPrefix:@"https://"] ||
        [trimmed hasPrefix:@"camscanner"] || [trimmed containsString:@"camscanner.com"] ||
        [trimmed containsString:@"intsig.net"]) {
        if ([trimmed rangeOfString:@"Scanned with CamScanner" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [trimmed rangeOfString:@"Digitalizado com" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return @"";
        }
        return input;
    }
    if ([input rangeOfString:@"Scanned with CamScanner" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [input rangeOfString:@"Digitalizado com CamScanner" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [input rangeOfString:@"Digitalizado com o CamScanner" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return @"";
    }
    NSString *result = input;
    for (NSString *target in @[@"CamScanner+", @"CamScanner +", @"CamScanner", @"Camscanner", @"CAMSCANNER"]) {
        result = [result stringByReplacingOccurrencesOfString:target withString:@"DocScan Pro"];
    }
    return result;
}

void REASanitizeViewHierarchyBranding(UIView *root) {
    if (![root isKindOfClass:[UIView class]]) return;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    for (NSUInteger i = 0; i < queue.count && i < 512; i++) {
        UIView *view = queue[i];
        if ([view isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)view;
            NSString *clean = REASanitizeBrandText(label.text);
            if (clean && ![clean isEqualToString:label.text]) label.text = clean;
        } else if ([view isKindOfClass:[UIButton class]]) {
            UIButton *btn = (UIButton *)view;
            NSString *title = [btn titleForState:UIControlStateNormal];
            NSString *clean = REASanitizeBrandText(title);
            if (clean && ![clean isEqualToString:title]) [btn setTitle:clean forState:UIControlStateNormal];
        }
        if (queue.count < 512) [queue addObjectsFromArray:view.subviews];
    }
}

void REASanitizeControllerBranding(UIViewController *vc) {
    if (![vc isKindOfClass:[UIViewController class]]) return;
    if (vc.title.length) {
        NSString *clean = REASanitizeBrandText(vc.title);
        if (clean && ![clean isEqualToString:vc.title]) vc.title = clean;
    }
    if (vc.navigationItem.title.length) {
        NSString *clean = REASanitizeBrandText(vc.navigationItem.title);
        if (clean && ![clean isEqualToString:vc.navigationItem.title]) vc.navigationItem.title = clean;
    }
    if (vc.isViewLoaded) {
        REASanitizeViewHierarchyBranding(vc.view);
    }
}

static UIImage *imageFromCandidate(id item) {
    if (!item) return nil;
    if ([item isKindOfClass:[UIImage class]]) return (UIImage *)item;
    if ([item isKindOfClass:[NSData class]]) return [UIImage imageWithData:(NSData *)item];
    if ([item isKindOfClass:[NSString class]]) {
        NSString *path = (NSString *)item;
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
            return [UIImage imageWithContentsOfFile:path];
        }
        return nil;
    }
    for (NSString *selName in @[@"processedImagePath", @"enhanceImagePath", @"imagePath",
                                @"fullImagePath", @"originImagePath", @"filePath", @"path", @"image"]) {
        SEL sel = NSSelectorFromString(selName);
        if ([item respondsToSelector:sel]) {
            Method m = class_getInstanceMethod([item class], sel);
            if (m && REASignature(m, "@", @[])) {
                id val = ((id (*)(id, SEL))objc_msgSend)(item, sel);
                UIImage *img = imageFromCandidate(val);
                if (img) return img;
            }
        }
    }
    return nil;
}

static void collectImagesFromArray(NSArray *arr, NSMutableArray<UIImage *> *out) {
    if (![arr isKindOfClass:[NSArray class]]) return;
    for (id item in arr) {
        UIImage *img = imageFromCandidate(item);
        if (img && img.size.width > 16 && img.size.height > 16) {
            [out addObject:img];
        }
    }
}

NSArray<UIImage *> *REAExtractDocumentPageImages(UIViewController *vc) {
    NSMutableArray<UIImage *> *images = [NSMutableArray array];
    if (!vc) return images;

    // Tier 1: Known selectors on controller
    for (NSString *selName in @[@"exportPageImages", @"pageImages", @"selectedImagePaths",
                                @"dataArray", @"pageArray", @"pages", @"imageArray"]) {
        SEL sel = NSSelectorFromString(selName);
        if ([vc respondsToSelector:sel]) {
            Method m = class_getInstanceMethod([vc class], sel);
            if (m && REASignature(m, "@", @[])) {
                id val = ((id (*)(id, SEL))objc_msgSend)(vc, sel);
                if ([val isKindOfClass:[NSArray class]]) {
                    collectImagesFromArray((NSArray *)val, images);
                    if (images.count > 0) return images;
                }
            }
        }
    }

    // Tier 2: Objective-C ivar inspection on controller
    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList([vc class], &ivarCount);
    if (ivars) {
        for (unsigned int i = 0; i < ivarCount; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (type && type[0] == '@') {
                id val = object_getIvar(vc, ivars[i]);
                if ([val isKindOfClass:[NSArray class]]) {
                    collectImagesFromArray((NSArray *)val, images);
                    if (images.count > 0) break;
                } else if ([val isKindOfClass:[UIImage class]]) {
                    UIImage *img = (UIImage *)val;
                    if (img.size.width >= 120 && img.size.height >= 120) [images addObject:img];
                }
            }
        }
        free(ivars);
    }
    if (images.count > 0) return images;

    // Tier 3: High-resolution UIImageViews in view hierarchy / collectionView
    if (vc.isViewLoaded && vc.view) {
        NSMutableArray<UIImageView *> *imgViews = [NSMutableArray array];
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:vc.view];
        for (NSUInteger i = 0; i < queue.count && i < 512; i++) {
            UIView *v = queue[i];
            if ([v isKindOfClass:[UIImageView class]]) {
                UIImageView *iv = (UIImageView *)v;
                if (!iv.hidden && iv.alpha > 0.05 && iv.image &&
                    iv.image.size.width >= 120 && iv.image.size.height >= 120) {
                    [imgViews addObject:iv];
                }
            }
            if (queue.count < 512) [queue addObjectsFromArray:v.subviews];
        }
        [imgViews sortUsingComparator:^NSComparisonResult(UIImageView *a, UIImageView *b) {
            CGRect fa = [a convertRect:a.bounds toView:vc.view];
            CGRect fb = [b convertRect:b.bounds toView:vc.view];
            if (fabs(fa.origin.y - fb.origin.y) > 20) {
                return fa.origin.y < fb.origin.y ? NSOrderedAscending : NSOrderedDescending;
            }
            return fa.origin.x < fb.origin.x ? NSOrderedAscending : NSOrderedDescending;
        }];
        for (UIImageView *iv in imgViews) {
            if (![images containsObject:iv.image]) [images addObject:iv.image];
        }
        if (images.count > 0) return images;

        // Tier 4 fallback: Render view snapshot if non-empty
        if (vc.view.bounds.size.width > 40 && vc.view.bounds.size.height > 40) {
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithBounds:vc.view.bounds];
            UIImage *snap = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                [vc.view.layer renderInContext:ctx.CGContext];
            }];
            if (snap) [images addObject:snap];
        }
    }
    return images;
}

static NSString *escapeHTML(NSString *str) {
    if (!str) return @"";
    NSString *s = [str stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
    s = [s stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
    s = [s stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
    s = [s stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
    return s;
}

static NSString *escapeCSV(NSString *str) {
    if (!str) return @"\"\"";
    NSString *escaped = [str stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""];
    return [NSString stringWithFormat:@"\"%@\"", escaped];
}

static NSArray<NSDictionary *> *recognizeTextElementsOnImage(UIImage *image) {
    NSMutableArray<NSDictionary *> *elements = [NSMutableArray array];
    CGImageRef cgImg = image.CGImage;
    if (!cgImg) return elements;

    for (NSNumber *levelNum in @[@(VNRequestTextRecognitionLevelAccurate), @(VNRequestTextRecognitionLevelFast)]) {
        [elements removeAllObjects];
        VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] init];
        req.recognitionLevel = (VNRequestTextRecognitionLevel)levelNum.integerValue;
        req.usesLanguageCorrection = (req.recognitionLevel == VNRequestTextRecognitionLevelAccurate);
        req.recognitionLanguages = @[@"pt-BR", @"en-US", @"es-ES"];

        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cgImg options:@{}];
        NSError *err = nil;
        [handler performRequests:@[req] error:&err];
        for (VNRecognizedTextObservation *obs in req.results) {
            VNRecognizedText *top = [[obs topCandidates:1] firstObject];
            NSString *text = [top.string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (text.length == 0) continue;
            CGRect bbox = obs.boundingBox; // normalized (origin at bottom-left)
            double topY = 1.0 - (bbox.origin.y + bbox.size.height * 0.5);
            [elements addObject:@{
                @"text": REASanitizeBrandText(text),
                @"x": @(bbox.origin.x),
                @"y": @(topY),
                @"w": @(bbox.size.width),
                @"h": @(bbox.size.height),
                @"bbox": [NSValue valueWithCGRect:bbox]
            }];
        }
        if (elements.count > 0) break;
    }
    return elements;
}

static NSArray<NSArray<NSDictionary *> *> *clusterRowsFromElements(NSArray<NSDictionary *> *elements) {
    if (elements.count == 0) return @[];
    NSArray<NSDictionary *> *sortedByY = [elements sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        double ya = [a[@"y"] doubleValue];
        double yb = [b[@"y"] doubleValue];
        if (fabs(ya - yb) > 0.0001) return ya < yb ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"x"] doubleValue] < [b[@"x"] doubleValue] ? NSOrderedAscending : NSOrderedDescending;
    }];

    NSMutableArray<NSMutableArray<NSDictionary *> *> *rows = [NSMutableArray array];
    for (NSDictionary *el in sortedByY) {
        double y = [el[@"y"] doubleValue];
        NSMutableArray<NSDictionary *> *matchedRow = nil;
        for (NSMutableArray<NSDictionary *> *row in rows) {
            double rowY = [row.firstObject[@"y"] doubleValue];
            if (fabs(y - rowY) <= 0.025) {
                matchedRow = row;
                break;
            }
        }
        if (!matchedRow) {
            matchedRow = [NSMutableArray array];
            [rows addObject:matchedRow];
        }
        [matchedRow addObject:el];
    }

    for (NSMutableArray<NSDictionary *> *row in rows) {
        [row sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            double xa = [a[@"x"] doubleValue];
            double xb = [b[@"x"] doubleValue];
            return xa < xb ? NSOrderedAscending : NSOrderedDescending;
        }];
    }
    return rows;
}

NSDictionary *REAGenerateProExportBundle(NSArray<UIImage *> *pages, NSString *documentTitle, NSString *outputDirectory) {
    if (!pages.count) return @{@"status": @"empty", @"pageCount": @0};
    NSString *rawTitle = REASanitizeBrandText(documentTitle.length ? documentTitle : @"Documento-DocScanPro");
    NSCharacterSet *illegal = [NSCharacterSet characterSetWithCharactersInString:@"/\\?%*|\"<>:"];
    NSString *safeTitle = [[rawTitle componentsSeparatedByCharactersInSet:illegal] componentsJoinedByString:@"-"];
    if (!safeTitle.length) safeTitle = @"Documento-DocScanPro";

    NSString *dir = outputDirectory.length ? outputDirectory : [NSTemporaryDirectory() stringByAppendingPathComponent:@"DocScanPro-Export"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *pdfPath = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-DocScanPro.pdf", safeTitle]];
    NSString *wordPath = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-Word.doc", safeTitle]];
    NSString *excelPath = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-Excel.csv", safeTitle]];
    NSString *txtPath = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-OCR.txt", safeTitle]];

    NSMutableString *txtOut = [NSMutableString string];
    NSMutableString *csvOut = [NSMutableString stringWithString:@"\uFEFF"]; // UTF-8 BOM for Excel
    NSMutableString *wordOut = [NSMutableString stringWithFormat:
        @"<!DOCTYPE html><html xmlns:o='urn:schemas-microsoft-com:office:office' "
        @"xmlns:w='urn:schemas-microsoft-com:office:word' xmlns='http://www.w3.org/TR/REC-html40'>"
        @"<head><meta charset='utf-8'><title>%@</title>"
        @"<style>body{font-family:Calibri,Arial,sans-serif;font-size:11pt;color:#1a1a1a;} "
        @"h2{color:#0b6e58;border-bottom:1px solid #d0e2dd;padding-bottom:4px;} "
        @"table{border-collapse:collapse;width:100%%;margin:8px 0;} "
        @"td{border:1px solid #b8ccc6;padding:6px 8px;font-size:10.5pt;} "
        @"p{margin:5px 0;line-height:1.35;}</style></head><body><h1>%@</h1>",
        escapeHTML(safeTitle), escapeHTML(safeTitle)];

    NSMutableArray<NSArray<NSDictionary *> *> *allPageElements = [NSMutableArray array];
    NSUInteger totalLines = 0;
    NSUInteger totalTableRows = 0;

    for (NSUInteger idx = 0; idx < pages.count; idx++) {
        UIImage *pageImg = pages[idx];
        NSArray<NSDictionary *> *elements = recognizeTextElementsOnImage(pageImg);
        [allPageElements addObject:elements];
        NSArray<NSArray<NSDictionary *> *> *rows = clusterRowsFromElements(elements);

        [txtOut appendFormat:@"=== P\u00e1gina %lu ===\n", (unsigned long)(idx + 1)];
        [wordOut appendFormat:@"<h2>P\u00e1gina %lu</h2>", (unsigned long)(idx + 1)];

        BOOL inTable = NO;
        for (NSArray<NSDictionary *> *row in rows) {
            totalLines++;
            NSMutableArray<NSString *> *cols = [NSMutableArray array];
            for (NSDictionary *cell in row) {
                [cols addObject:cell[@"text"] ?: @""];
            }
            NSString *joinedLine = [cols componentsJoinedByString:@"    "];
            [txtOut appendFormat:@"%@\n", joinedLine];

            // Write row to Excel CSV
            NSMutableArray<NSString *> *csvCells = [NSMutableArray array];
            for (NSString *c in cols) [csvCells addObject:escapeCSV(c)];
            [csvOut appendFormat:@"%@\r\n", [csvCells componentsJoinedByString:@","]];

            if (cols.count >= 2) {
                totalTableRows++;
                if (!inTable) {
                    [wordOut appendString:@"<table>"];
                    inTable = YES;
                }
                [wordOut appendString:@"<tr>"];
                for (NSString *c in cols) {
                    [wordOut appendFormat:@"<td>%@</td>", escapeHTML(c)];
                }
                [wordOut appendString:@"</tr>"];
            } else {
                if (inTable) {
                    [wordOut appendString:@"</table>"];
                    inTable = NO;
                }
                [wordOut appendFormat:@"<p>%@</p>", escapeHTML(cols.firstObject ?: @"")];
            }
        }
        if (inTable) [wordOut appendString:@"</table>"];
        [txtOut appendString:@"\n"];
    }
    [wordOut appendString:@"</body></html>"];

    // Render clean watermark-free searchable PDF
    UIGraphicsPDFRenderer *pdfRenderer = [[UIGraphicsPDFRenderer alloc] initWithBounds:CGRectMake(0, 0, 595.2, 841.8)];
    NSData *pdfData = [pdfRenderer PDFDataWithActions:^(UIGraphicsPDFRendererContext *ctx) {
        for (NSUInteger idx = 0; idx < pages.count; idx++) {
            UIImage *img = pages[idx];
            CGSize sz = img.size;
            CGRect pageRect = (sz.width > 32 && sz.height > 32) ? CGRectMake(0, 0, sz.width, sz.height) : CGRectMake(0, 0, 595.2, 841.8);
            [ctx beginPageWithBounds:pageRect pageInfo:@{}];
            [img drawInRect:pageRect];

            // Overlay invisible selectable OCR text (zero watermark)
            NSArray<NSDictionary *> *elements = allPageElements[idx];
            for (NSDictionary *el in elements) {
                NSString *t = el[@"text"];
                CGRect bbox = [el[@"bbox"] CGRectValue];
                CGFloat x = bbox.origin.x * pageRect.size.width;
                CGFloat h = MAX(10.0, bbox.size.height * pageRect.size.height);
                CGFloat y = (1.0 - bbox.origin.y - bbox.size.height) * pageRect.size.height;
                CGFloat w = MAX(20.0, bbox.size.width * pageRect.size.width);
                NSDictionary *attrs = @{
                    NSFontAttributeName: [UIFont systemFontOfSize:MAX(8.0, h * 0.75)],
                    NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.01]
                };
                [t drawInRect:CGRectMake(x, y, w, h) withAttributes:attrs];
            }
        }
    }];

    [pdfData writeToFile:pdfPath atomically:YES];
    [[wordOut dataUsingEncoding:NSUTF8StringEncoding] writeToFile:wordPath atomically:YES];
    [[csvOut dataUsingEncoding:NSUTF8StringEncoding] writeToFile:excelPath atomically:YES];
    [[txtOut dataUsingEncoding:NSUTF8StringEncoding] writeToFile:txtPath atomically:YES];

    return @{
        @"status": @"ok",
        @"title": safeTitle,
        @"pageCount": @(pages.count),
        @"recognizedLineCount": @(totalLines),
        @"tableRowCount": @(totalTableRows),
        @"pdfPath": pdfPath,
        @"wordPath": wordPath,
        @"excelPath": excelPath,
        @"txtPath": txtPath,
        @"allPaths": @[pdfPath, wordPath, excelPath, txtPath]
    };
}

static void shareFilesFromController(UIViewController *vc, NSArray<NSString *> *paths, UIView *sourceView) {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSString *p in paths) {
        if ([NSFileManager.defaultManager fileExistsAtPath:p]) {
            [urls addObject:[NSURL fileURLWithPath:p]];
        }
    }
    if (!urls.count || !vc) return;
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:urls applicationActivities:nil];
    if (activity.popoverPresentationController) {
        activity.popoverPresentationController.sourceView = sourceView ?: vc.view;
        activity.popoverPresentationController.sourceRect = sourceView ? sourceView.bounds : CGRectMake(CGRectGetMidX(vc.view.bounds), 44, 1, 1);
    }
    [vc presentViewController:activity animated:YES completion:nil];
}

void REAPresentProExportSheet(UIViewController *vc) {
    if (!vc) return;
    NSArray<UIImage *> *pages = REAExtractDocumentPageImages(vc);
    if (!pages.count) return;
    NSString *title = vc.navigationItem.title.length ? vc.navigationItem.title : (vc.title.length ? vc.title : @"Documento");
    NSDictionary *bundle = REAGenerateProExportBundle(pages, title, nil);
    if (![bundle[@"status"] isEqualToString:@"ok"]) return;

    NSString *summary = [NSString stringWithFormat:@"%lu p\u00e1gina(s) processada(s) no aparelho (%lu linha(s) OCR, zero marca d'\u00e1gua).",
                         (unsigned long)[bundle[@"pageCount"] unsignedIntegerValue],
                         (unsigned long)[bundle[@"recognizedLineCount"] unsignedIntegerValue]];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Exportar Pro \u2014 DocScan Pro"
                                                                   message:summary
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak UIViewController *weakVC = vc;
    NSArray<NSArray<NSString *> *> *options = @[
        @[@"PDF Limpo (Sem Marca d'\u00c1gua)", bundle[@"pdfPath"]],
        @[@"Word (.doc Edit\u00e1vel com OCR)", bundle[@"wordPath"]],
        @[@"Planilha Excel (.csv Tabelas)", bundle[@"excelPath"]],
        @[@"Texto OCR (.txt)", bundle[@"txtPath"]]
    ];
    for (NSArray<NSString *> *opt in options) {
        [sheet addAction:[UIAlertAction actionWithTitle:opt[0] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            shareFilesFromController(weakVC, @[opt[1]], weakVC.view);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Pacote Completo (PDF + Word + Excel + TXT)"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        shareFilesFromController(weakVC, bundle[@"allPaths"], weakVC.view);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = vc.view;
        sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(vc.view.bounds), 44, 1, 1);
    }
    [vc presentViewController:sheet animated:YES completion:nil];
}
